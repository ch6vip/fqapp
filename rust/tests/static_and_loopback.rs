//! F1 (path confinement) and F2 (Range/HEAD/streaming) regression tests.
//!
//! Both the in-process dispatcher and the real loopback HTTP adapter are
//! exercised, because the FFI path materialises the body while the HTTP path
//! streams it.

mod common;

use common::{build_server, pool_json, start_loopback, TempDir};
use fqapi_core::dispatch::{dispatch, Request, ResponseBody};

const MARKER: &str = "OFFLINE_TEST_MARKER_OUTSIDE_SRC";

async fn fixture() -> (TempDir, std::sync::Arc<fqapi_core::endpoints::Server>) {
    let dir = TempDir::new("static");
    let server = build_server(
        &dir,
        None,
        &[
            ("index.html", "<html>index</html>"),
            ("assets/css/all.min.css", "body{}"),
        ],
        &[("ok.txt", "0123456789")],
        &pool_json(5),
    )
    .await;
    // A sibling of src/ that must never be reachable through /src/.
    dir.write("outside.txt", MARKER);
    (dir, server)
}

fn get(path: &str, headers: &[(&str, &str)]) -> Request {
    Request {
        method: "GET".to_string(),
        path: path.to_string(),
        query: String::new(),
        body: Vec::new(),
        headers: headers
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
    }
}

async fn body_string(
    server: &fqapi_core::endpoints::Server,
    req: &Request,
) -> (u16, String, Vec<(String, String)>) {
    let resp = dispatch(server, req).await;
    let status = resp.status;
    let headers = resp.headers.clone();
    let body = resp.into_bytes().await.expect("body");
    (status, String::from_utf8_lossy(&body).into_owned(), headers)
}

#[tokio::test]
async fn serves_a_file_inside_the_resource_root() {
    let (_dir, server) = fixture().await;
    let (status, body, _) = body_string(&server, &get("/src/ok.txt", &[])).await;
    assert_eq!(status, 200);
    assert_eq!(body, "0123456789");
}

#[tokio::test]
async fn refuses_to_escape_the_resource_root() {
    let (_dir, server) = fixture().await;
    for path in [
        "/src/../outside.txt",
        "/src/%2e%2e/outside.txt",
        "/src/..%2Foutside.txt",
        "/src/subdir/../../outside.txt",
        "/src/./../outside.txt",
        "/src/..\\outside.txt",
    ] {
        let (status, body, _) = body_string(&server, &get(path, &[])).await;
        assert_eq!(status, 404, "path {path:?} must not be served");
        assert!(
            !body.contains(MARKER),
            "path {path:?} leaked the file outside src/"
        );
    }
}

#[tokio::test]
async fn refuses_encoded_and_absolute_components() {
    let (_dir, server) = fixture().await;
    for path in [
        "/src/%2e%2e%2foutside.txt",
        "/assets/../../outside.txt",
        "/assets/%2e%2e/%2e%2e/outside.txt",
        "/index.html/../../outside.txt",
    ] {
        let (status, body, _) = body_string(&server, &get(path, &[])).await;
        assert_eq!(status, 404, "path {path:?} must not be served");
        assert!(!body.contains(MARKER), "path {path:?} leaked a file");
    }
}

#[tokio::test]
async fn directory_without_an_index_is_not_listed() {
    let (_dir, server) = fixture().await;
    let (status, _, _) = body_string(&server, &get("/src", &[])).await;
    assert_eq!(status, 404);
}

#[tokio::test]
async fn serves_the_web_root_and_index() {
    let (_dir, server) = fixture().await;
    let (status, body, _) = body_string(&server, &get("/", &[])).await;
    assert_eq!(status, 200);
    assert_eq!(body, "<html>index</html>");

    let (status, body, _) = body_string(&server, &get("/index.html", &[])).await;
    assert_eq!(status, 200);
    assert_eq!(body, "<html>index</html>");
}

#[tokio::test]
async fn range_requests_return_206_with_content_range() {
    let (_dir, server) = fixture().await;
    let (status, body, headers) =
        body_string(&server, &get("/src/ok.txt", &[("range", "bytes=2-5")])).await;
    assert_eq!(status, 206);
    assert_eq!(body, "2345");
    let header = |name: &str| {
        headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    assert_eq!(header("content-range"), "bytes 2-5/10");
    assert_eq!(header("content-length"), "4");
    assert_eq!(header("accept-ranges"), "bytes");
}

#[tokio::test]
async fn range_variants_are_handled_like_the_go_file_server() {
    let (_dir, server) = fixture().await;

    // Open-ended range.
    let (status, body, headers) =
        body_string(&server, &get("/src/ok.txt", &[("range", "bytes=6-")])).await;
    assert_eq!((status, body.as_str()), (206, "6789"));
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-range")
            .map(|(_, v)| v.as_str()),
        Some("bytes 6-9/10")
    );

    // Suffix range: the last three bytes.
    let (status, body, _) =
        body_string(&server, &get("/src/ok.txt", &[("range", "bytes=-3")])).await;
    assert_eq!((status, body.as_str()), (206, "789"));

    // End past the resource is clamped.
    let (status, body, headers) =
        body_string(&server, &get("/src/ok.txt", &[("range", "bytes=8-99")])).await;
    assert_eq!((status, body.as_str()), (206, "89"));
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-range")
            .map(|(_, v)| v.as_str()),
        Some("bytes 8-9/10")
    );

    // Unsatisfiable range.
    let (status, body, headers) =
        body_string(&server, &get("/src/ok.txt", &[("range", "bytes=99-")])).await;
    assert_eq!(status, 416);
    assert!(body.is_empty());
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-range")
            .map(|(_, v)| v.as_str()),
        Some("bytes */10")
    );

    // A malformed header is ignored rather than failing the request.
    let (status, body, _) =
        body_string(&server, &get("/src/ok.txt", &[("range", "items=1-2")])).await;
    assert_eq!((status, body.as_str()), (200, "0123456789"));
}

#[tokio::test]
async fn head_returns_headers_without_a_body() {
    let (_dir, server) = fixture().await;
    let mut req = get("/src/ok.txt", &[]);
    req.method = "HEAD".to_string();
    let (status, body, headers) = body_string(&server, &req).await;
    assert_eq!(status, 200);
    assert!(body.is_empty());
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .map(|(_, v)| v.as_str()),
        Some("10")
    );
}

#[tokio::test]
async fn file_bodies_are_ranges_not_whole_files() {
    let (_dir, server) = fixture().await;
    let resp = dispatch(&server, &get("/src/ok.txt", &[("range", "bytes=1-3")])).await;
    match resp.body {
        ResponseBody::File {
            offset,
            length,
            total,
            ..
        } => {
            assert_eq!((offset, length, total), (1, 3, 10));
        }
        ResponseBody::Bytes(bytes) => panic!("expected a file range, got {} bytes", bytes.len()),
    }
}

// --- Real loopback adapter -------------------------------------------------

async fn http_get(
    port: u16,
    path: &str,
    range: Option<&str>,
) -> (u16, Vec<(String, String)>, Vec<u8>) {
    let client = reqwest::Client::builder().build().expect("client");
    let mut builder = client.get(format!("http://127.0.0.1:{port}{path}"));
    if let Some(r) = range {
        builder = builder.header("range", r);
    }
    let resp = builder.send().await.expect("loopback request");
    let status = resp.status().as_u16();
    let headers: Vec<(String, String)> = resp
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).into_owned(),
            )
        })
        .collect();
    let body = resp.bytes().await.expect("body").to_vec();
    (status, headers, body)
}

#[tokio::test]
async fn loopback_adapter_serves_plain_and_ranged_requests() {
    let (_dir, server) = fixture().await;
    let (port, task) = start_loopback(server).await;

    let (status, _, body) = http_get(port, "/src/ok.txt", None).await;
    assert_eq!(status, 200);
    assert_eq!(body, b"0123456789");

    let (status, headers, body) = http_get(port, "/src/ok.txt", Some("bytes=2-5")).await;
    assert_eq!(status, 206);
    assert_eq!(body, b"2345");
    let header = |name: &str| {
        headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
            .to_string()
    };
    assert_eq!(header("content-range"), "bytes 2-5/10");
    assert_eq!(header("accept-ranges"), "bytes");

    task.abort();
}

#[tokio::test]
async fn loopback_adapter_refuses_traversal_over_a_real_socket() {
    let (_dir, server) = fixture().await;
    let (port, task) = start_loopback(server).await;

    for path in [
        "/src/../outside.txt",
        "/src/%2e%2e/outside.txt",
        "/src/..%2Foutside.txt",
    ] {
        let (status, _, body) = http_get(port, path, None).await;
        assert_eq!(status, 404, "path {path:?}");
        assert!(!String::from_utf8_lossy(&body).contains(MARKER));
    }
    task.abort();
}

#[tokio::test]
async fn loopback_adapter_streams_a_large_file_in_bounded_chunks() {
    let dir = TempDir::new("static-large");
    let server = build_server(&dir, None, &[], &[], &pool_json(5)).await;
    // 4 MiB is far beyond any single read buffer.
    let big = vec![b'x'; 4 * 1024 * 1024];
    let mut tail = big.clone();
    tail[..1].copy_from_slice(b"z");
    std::fs::write(dir.join("src/big.bin"), &tail).expect("write big file");
    let (port, task) = start_loopback(server).await;

    let (status, headers, body) = http_get(port, "/src/big.bin", None).await;
    assert_eq!(status, 200);
    assert_eq!(body.len(), tail.len());
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .map(|(_, v)| v.as_str()),
        Some("4194304")
    );

    let (status, headers, body) =
        http_get(port, "/src/big.bin", Some("bytes=4194300-4194303")).await;
    assert_eq!(status, 206);
    assert_eq!(body.len(), 4);
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-range")
            .map(|(_, v)| v.as_str()),
        Some("bytes 4194300-4194303/4194304")
    );
    task.abort();
}

// --- F1-R / F2-R regressions -----------------------------------------------

#[cfg(windows)]
fn symlink_file(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> {
    std::os::windows::fs::symlink_file(target, link)
}

#[cfg(not(windows))]
fn symlink_file(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

/// Fixture with the boundary cases: an index symlinked out of the root, a
/// symlink that stays inside it, an empty media file, and a plain subdirectory.
async fn boundary_fixture() -> (TempDir, std::sync::Arc<fqapi_core::endpoints::Server>) {
    let dir = TempDir::new("boundary");
    let server = build_server(
        &dir,
        None,
        &[],
        &[
            ("ok.txt", "0123456789"),
            ("empty.mp4", ""),
            ("sub/index.html", "<html>sub</html>"),
        ],
        &pool_json(5),
    )
    .await;
    dir.write("outside.txt", MARKER);

    let linked = dir.join("src/linked");
    std::fs::create_dir_all(&linked).expect("linked dir");
    symlink_file(&dir.join("outside.txt"), &linked.join("index.html")).unwrap_or_else(|e| {
        panic!("this test needs symlink support (Windows: enable Developer Mode): {e}")
    });

    symlink_file(&dir.join("src/ok.txt"), &dir.join("src/inside-link.txt"))
        .unwrap_or_else(|e| panic!("this test needs symlink support: {e}"));

    (dir, server)
}

#[tokio::test]
async fn directory_index_inside_the_root_is_served() {
    let (_dir, server) = boundary_fixture().await;
    let (status, body, _) = body_string(&server, &get("/src/sub/", &[])).await;
    assert_eq!(status, 200);
    assert_eq!(body, "<html>sub</html>");
}

#[tokio::test]
async fn an_index_symlinked_out_of_the_root_is_refused() {
    let (_dir, server) = boundary_fixture().await;

    for path in ["/src/linked/", "/src/linked/index.html"] {
        let (status, body, _) = body_string(&server, &get(path, &[])).await;
        assert_eq!(status, 404, "path {path:?} must not be served");
        assert!(
            !body.contains(MARKER),
            "path {path:?} leaked a file outside src/"
        );
    }
}

#[tokio::test]
async fn a_symlink_that_stays_inside_the_root_is_still_served() {
    let (_dir, server) = boundary_fixture().await;
    let (status, body, _) = body_string(&server, &get("/src/inside-link.txt", &[])).await;
    assert_eq!(status, 200);
    assert_eq!(body, "0123456789");
}

#[tokio::test]
async fn empty_file_ranges_are_ignored_with_consistent_headers() {
    let (_dir, server) = boundary_fixture().await;

    for range in ["bytes=0-", "bytes=0-0", "bytes=-1", "bytes=99-"] {
        let (status, body, headers) =
            body_string(&server, &get("/src/empty.mp4", &[("range", range)])).await;
        assert_eq!(status, 200, "range {range:?} on an empty file");
        assert!(body.is_empty());
        let header = |name: &str| {
            headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.as_str().to_string())
        };
        assert_eq!(
            header("content-length").as_deref(),
            Some("0"),
            "range {range:?}"
        );
        assert_eq!(header("content-range"), None, "range {range:?}");
        assert_eq!(header("accept-ranges").as_deref(), Some("bytes"));
    }

    // The in-process path must materialise the same empty body without an error
    // (this used to be "early eof" because the declared length was 1).
    let resp = dispatch(&server, &get("/src/empty.mp4", &[("range", "bytes=0-")])).await;
    let bytes = resp
        .into_bytes()
        .await
        .expect("empty body must materialise");
    assert!(bytes.is_empty());
}

#[tokio::test]
async fn declared_length_always_matches_the_body() {
    let (_dir, server) = boundary_fixture().await;

    let cases: [(&str, u16, usize); 4] = [
        ("bytes=2-5", 206, 4),
        ("bytes=0-", 206, 10),
        ("bytes=-3", 206, 3),
        ("bytes=99-", 416, 0),
    ];
    for (range, want_status, want_len) in cases {
        let resp = dispatch(&server, &get("/src/ok.txt", &[("range", range)])).await;
        let status = resp.status;
        let declared: usize = resp
            .headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .map(|(_, v)| v.parse().expect("content-length"))
            .unwrap_or(0);
        let body = resp.into_bytes().await.expect("body");
        assert_eq!(status, want_status, "range {range:?}");
        assert_eq!(declared, want_len, "range {range:?} declared length");
        assert_eq!(body.len(), declared, "range {range:?} body length");
    }
}

#[tokio::test]
async fn loopback_adapter_refuses_a_symlinked_index_and_serves_empty_files() {
    let (_dir, server) = boundary_fixture().await;
    let (port, task) = start_loopback(server).await;

    let (status, _, body) = http_get(port, "/src/linked/", None).await;
    assert_eq!(status, 404);
    assert!(!String::from_utf8_lossy(&body).contains(MARKER));

    let (status, headers, body) = http_get(port, "/src/empty.mp4", Some("bytes=0-")).await;
    assert_eq!(status, 200);
    assert!(body.is_empty(), "an empty file must send no bytes");
    assert_eq!(
        headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .map(|(_, v)| v.as_str()),
        Some("0")
    );

    let (status, _, body) = http_get(port, "/src/sub/", None).await;
    assert_eq!(status, 200);
    assert_eq!(body, b"<html>sub</html>");

    task.abort();
}
