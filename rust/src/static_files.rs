//! Confined static file serving with Range/HEAD support.
//!
//! `http.FileServer` (the reference implementation) refuses `..` path segments but follows
//! symbolic links out of its root. The loopback adapter must be stricter: the
//! runtime directory also holds the device pool and the configuration, so every
//! served path - including a directory's `index.html` fallback - is
//! canonicalised (which resolves symlinks) and must still live inside the
//! canonical root.
//!
//! Actual path rules (they are easy to mis-state):
//!   * the request suffix is percent-decoded exactly once;
//!   * backslashes are normalised to `/`;
//!   * empty and `.` segments are skipped;
//!   * a `..` segment, a `:` (drive letter or NTFS alternate data stream) or a
//!     NUL byte refuses the whole request;
//!   * the joined path is canonicalised and must start with the canonical root;
//!   * only regular files are served, and a directory falls back to
//!     `index.html` which is validated by the same rules;
//!   * `HEAD` returns the headers with no body;
//!   * `Range: bytes=…` returns 206 + `Content-Range`, an unsatisfiable range
//!     returns 416 + `Content-Range: bytes */<total>`, and a range on an empty
//!     resource is ignored (200 + zero-length body) so status, headers and body
//!     always agree;
//!   * every response carries `Accept-Ranges: bytes`.

use std::path::{Path, PathBuf};

use percent_encoding::percent_decode_str;

use crate::dispatch::{Request, Response, ResponseBody};

/// Upper bound for the in-process (FFI) path, which must return a `Vec<u8>`.
/// The loopback HTTP adapter streams file bodies instead and is not capped.
pub const FFI_BODY_LIMIT: u64 = 64 * 1024 * 1024;

/// Builds the candidate path from the (single-pass decoded) request suffix.
/// Returns `None` for anything that must not be turned into a path.
fn candidate_path(root: &Path, raw_suffix: &str) -> Option<PathBuf> {
    let decoded = percent_decode_str(raw_suffix).decode_utf8().ok()?;
    let normalised = decoded.replace('\\', "/");

    let mut candidate = root.to_path_buf();
    for segment in normalised.split('/') {
        if segment.is_empty() || segment == "." {
            continue;
        }
        if segment == ".." {
            return None;
        }
        // ':' addresses a drive or an NTFS alternate data stream; NUL is never
        // a legal file name component.
        if segment.contains(':') || segment.contains('\0') {
            return None;
        }
        candidate.push(segment);
    }
    Some(candidate)
}

/// Canonicalises `candidate` and requires it to be a regular file inside
/// `canonical_root`. Symlinks are resolved first, so a link that points out of
/// the root is refused.
async fn confine(canonical_root: &Path, candidate: &Path) -> Option<PathBuf> {
    let canonical = tokio::fs::canonicalize(candidate).await.ok()?;
    if !canonical.starts_with(canonical_root) {
        return None;
    }
    match tokio::fs::metadata(&canonical).await {
        Ok(meta) if meta.is_file() => Some(canonical),
        _ => None,
    }
}

/// Resolves a request suffix inside `root`, refusing anything that could leave
/// it. Returns the canonical path of a regular file.
pub async fn resolve_confined(root: &Path, raw_suffix: &str) -> Option<PathBuf> {
    let candidate = candidate_path(root, raw_suffix)?;
    let canonical_root = tokio::fs::canonicalize(root).await.ok()?;

    if let Some(path) = confine(&canonical_root, &candidate).await {
        return Some(path);
    }

    // Directory fallback. The joined index is validated by exactly the same
    // rules as a directly requested file, which is what closes the symlinked
    // index escape.
    confine(&canonical_root, &candidate.join("index.html")).await
}

/// Parsed `Range: bytes=…` header for a resource of `total` bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ByteRange {
    /// No usable range header: serve the whole resource.
    Full,
    /// An explicit inclusive range, already clamped to the resource size.
    Partial { start: u64, end: u64 },
    /// Syntactically valid but outside the resource: 416.
    Unsatisfiable,
}

/// Parses a single-range `bytes=` header.
///
/// Multi-range requests are deliberately treated as `Full`: the response is
/// still complete and correct, and the media clients on this path only ever
/// send a single range.
pub fn parse_range(header: Option<&str>, total: u64) -> ByteRange {
    let Some(raw) = header else {
        return ByteRange::Full;
    };
    let Some(spec) = raw.trim().strip_prefix("bytes=") else {
        return ByteRange::Full;
    };
    if spec.contains(',') {
        return ByteRange::Full;
    }

    // An empty resource cannot satisfy any range. Go's FileServer also ignores
    // the header for size 0 (`bytes=0-`, `bytes=0-0`, `bytes=99-`), and only
    // diverges for a suffix range, where it emits the malformed
    // `Content-Range: bytes 0--1/0`. Ignoring every range here keeps status,
    // headers and body consistent, which is the property that matters.
    if total == 0 {
        return ByteRange::Full;
    }

    let Some((start_raw, end_raw)) = spec.trim().split_once('-') else {
        return ByteRange::Unsatisfiable;
    };
    let start_raw = start_raw.trim();
    let end_raw = end_raw.trim();

    if start_raw.is_empty() {
        // Suffix range: the last N bytes.
        let Ok(suffix) = end_raw.parse::<u64>() else {
            return ByteRange::Unsatisfiable;
        };
        if suffix == 0 {
            return ByteRange::Unsatisfiable;
        }
        let start = total.saturating_sub(suffix);
        return ByteRange::Partial {
            start,
            end: total - 1,
        };
    }

    let Ok(start) = start_raw.parse::<u64>() else {
        return ByteRange::Unsatisfiable;
    };
    if start >= total {
        return ByteRange::Unsatisfiable;
    }
    let end = if end_raw.is_empty() {
        total - 1
    } else {
        match end_raw.parse::<u64>() {
            Ok(e) => e.min(total - 1),
            Err(_) => return ByteRange::Unsatisfiable,
        }
    };
    if end < start {
        return ByteRange::Unsatisfiable;
    }
    ByteRange::Partial { start, end }
}

/// Serves one static file request.
pub async fn serve(root: &Path, raw_suffix: &str, req: &Request) -> Response {
    let Some(path) = resolve_confined(root, raw_suffix).await else {
        return Response::not_found(format!("not found: {}", Path::new(raw_suffix).display()));
    };
    let Ok(meta) = tokio::fs::metadata(&path).await else {
        return Response::not_found(format!("not found: {}", path.display()));
    };
    let total = meta.len();
    let content_type = crate::dispatch::mime_for(&path).to_string();

    let range = parse_range(req.header("range"), total);
    let is_head = req.method.eq_ignore_ascii_case("HEAD");

    let (status, offset, length, extra) = match range {
        ByteRange::Full => (200u16, 0u64, total, Vec::new()),
        ByteRange::Partial { start, end } => (
            206u16,
            start,
            end - start + 1,
            vec![(
                "content-range".to_string(),
                format!("bytes {start}-{end}/{total}"),
            )],
        ),
        ByteRange::Unsatisfiable => {
            // The declared length always matches the body that follows, which is
            // the property F2-R is about. (Go answers 416 with a short text body
            // and no Accept-Ranges; an empty body is equivalent for clients and
            // keeps length and payload in agreement.)
            return Response {
                status: 416,
                content_type,
                headers: vec![
                    ("accept-ranges".to_string(), "bytes".to_string()),
                    ("content-range".to_string(), format!("bytes */{total}")),
                    ("content-length".to_string(), "0".to_string()),
                ],
                body: ResponseBody::Bytes(Vec::new()),
            };
        }
    };

    let mut headers = vec![
        ("accept-ranges".to_string(), "bytes".to_string()),
        ("content-length".to_string(), length.to_string()),
    ];
    headers.extend(extra);

    if is_head {
        return Response {
            status,
            content_type,
            headers,
            body: ResponseBody::Bytes(Vec::new()),
        };
    }

    Response {
        status,
        content_type,
        headers,
        body: ResponseBody::File {
            path,
            offset,
            length,
            total,
        },
    }
}
