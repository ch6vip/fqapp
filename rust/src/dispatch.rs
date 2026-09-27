//! The single request dispatcher shared by the FFI bridge and the loopback
//! HTTP adapter. Port of `router.go` `Server.ServeHTTP`.
//!
//! Architecture decision and consequences:
//! .agents/notes/implemented/architecture/2026-09-23-rust-native-core-migration.md
//!
//! There is exactly one business implementation: Flutter reaches it over
//! flutter_rust_bridge and the built-in Web UI reaches it over loopback HTTP.

use std::path::{Path, PathBuf};

use serde_json::json;

use crate::endpoints::{router, Params, RawOut, Server};
use crate::error::ApiError;

#[derive(Debug, Clone, Default)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: String,
    pub body: Vec<u8>,
    /// Request headers, lower-cased by the adapter. Only the static file path
    /// consumes them today (Range/HEAD); business endpoints are unaffected.
    pub headers: Vec<(String, String)>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

/// Response body: either bytes already in memory, or a byte range of a file
/// the loopback adapter streams without reading it into memory.
#[derive(Debug, Clone)]
pub enum ResponseBody {
    Bytes(Vec<u8>),
    File {
        path: PathBuf,
        offset: u64,
        length: u64,
        total: u64,
    },
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    pub content_type: String,
    pub headers: Vec<(String, String)>,
    pub body: ResponseBody,
}

const JSON_CT: &str = "application/json; charset=utf-8";

impl Response {
    pub fn json(status: u16, value: &serde_json::Value) -> Self {
        Response {
            status,
            content_type: JSON_CT.to_string(),
            headers: Vec::new(),
            body: ResponseBody::Bytes(serde_json::to_vec(value).unwrap_or_default()),
        }
    }

    pub fn text(status: u16, content_type: impl Into<String>, body: Vec<u8>) -> Self {
        Response {
            status,
            content_type: content_type.into(),
            headers: Vec::new(),
            body: ResponseBody::Bytes(body),
        }
    }

    pub fn not_found(message: String) -> Self {
        Response::json(404, &json!({ "success": false, "error": message }))
    }

    /// Materialises the body into bytes. Used by the FFI transport and by
    /// tests; the loopback adapter streams `File` bodies instead.
    pub async fn into_bytes(self) -> Result<Vec<u8>, String> {
        match self.body {
            ResponseBody::Bytes(b) => Ok(b),
            ResponseBody::File {
                path,
                offset,
                length,
                ..
            } => {
                if length > crate::static_files::FFI_BODY_LIMIT {
                    return Err(format!(
                        "resource too large for the in-process transport: {length} bytes"
                    ));
                }
                read_range(&path, offset, length).await
            }
        }
    }
}

async fn read_range(path: &Path, offset: u64, length: u64) -> Result<Vec<u8>, String> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    if offset > 0 {
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| e.to_string())?;
    }
    let mut out = vec![0u8; length as usize];
    file.read_exact(&mut out).await.map_err(|e| e.to_string())?;
    Ok(out)
}

pub async fn dispatch(server: &Server, req: &Request) -> Response {
    let path = req.path.as_str();
    let ctx = &server.ctx;

    // --- Web UI static files and API bridge ---
    if path.starts_with("/api/") && !path.starts_with("/api/v1/") {
        return crate::endpoints::webui::handle(server, path, &Params::parse(&req.query)).await;
    }

    if let Some(rest) = path.strip_prefix("/assets/") {
        let root = Path::new(&ctx.web_dir).join("assets");
        return crate::static_files::serve(&root, rest, req).await;
    }

    if path == "/" || path.ends_with(".html") || path.ends_with(".ico") {
        let rel = path.trim_start_matches('/');
        return crate::static_files::serve(Path::new(&ctx.web_dir), rel, req).await;
    }

    if path == "/health" {
        let devices = ctx.pool.count().await;
        return Response::json(200, &json!({ "status": "ok", "devices": devices }));
    }

    // static image server for decrypted manga images
    if !ctx.src_dir.is_empty() && (path == "/src" || path.starts_with("/src/")) {
        let rest = path.strip_prefix("/src/").unwrap_or("");
        return crate::static_files::serve(Path::new(&ctx.src_dir), rest, req).await;
    }

    let mut params = Params::parse(&req.query);
    let m = match router::match_rest_path(path, &params) {
        Some(m) => m,
        None => {
            if ctx.cfg.anti_crawler.enabled && !ctx.cfg.anti_crawler.redirect_url.is_empty() {
                return Response::text(
                    302,
                    "text/plain; charset=utf-8",
                    ctx.cfg.anti_crawler.redirect_url.clone().into_bytes(),
                );
            }
            return Response::json(
                404,
                &json!({ "success": false, "error": format!("not found: {path}") }),
            );
        }
    };
    params = m.params;

    // HTML page endpoints write their own response and bypass the envelope.
    if let Some(raw) = server.raw_handler(m.api) {
        return match raw(ctx, &params).await {
            Ok(RawOut {
                status,
                content_type,
                body,
            }) => Response::text(status, content_type, body),
            Err(e) => {
                log::warn!("api {} failed: {}", m.api, e.message());
                error_response(&e)
            }
        };
    }

    let Some(ep) = server.handler(m.api) else {
        return Response::json(
            404,
            &json!({ "success": false, "error": format!("unsupported api type: {}", m.api) }),
        );
    };

    // Sessions opened by recommend pagination are bound to the device that
    // opened them; pin it so page N+1 does not rotate to a different device.
    if let Some(pin) = router::pin_from_session(&mut params, &ctx.pool).await {
        params.set(crate::endpoints::INTERNAL_DEVICE_PIN_KEY, pin);
    }

    match ep(ctx, &params).await {
        Ok(mut data) => {
            data = ctx.filters.apply(path, data);
            Response::json(200, &data)
        }
        Err(e) => {
            // Release builds have no console; this is the only trace a
            // business failure leaves in logcat (tag fqapi_core).
            log::warn!("api {} failed: {}", m.api, e.message());
            error_response(&e)
        }
    }
}

fn error_response(e: &ApiError) -> Response {
    Response::json(
        e.status(),
        &json!({ "success": false, "error": e.message() }),
    )
}

/// Minimal extension table for the bundled Web UI assets.
pub fn mime_for(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "html" | "htm" => "text/html; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "js" | "mjs" => "application/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "txt" => "text/plain; charset=utf-8",
        "ico" => "image/x-icon",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "eot" => "application/vnd.ms-fontobject",
        "mp4" => "video/mp4",
        "m4s" => "video/iso.segment",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    }
}
