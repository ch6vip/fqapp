//! The plain unsigned GET must honor its caller's body cap. It used to go
//! through the uncapped request path and buffer any response whole.

use super::*;

async fn serve_once(body: Vec<u8>) -> (u16, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind test server");
    let port = listener.local_addr().expect("test server addr").port();
    let handle = tokio::spawn(async move {
        if let Ok((mut socket, _)) = listener.accept().await {
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            let header = format!(
                "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                body.len()
            );
            let _ = socket.write_all(header.as_bytes()).await;
            let _ = socket.write_all(&body).await;
            let _ = socket.shutdown().await;
        }
    });
    (port, handle)
}

async fn test_ctx(origin: String, dir: &Path) -> Ctx {
    let pool = crate::device::DevicePool::with_mock_origin(dir.join("pool.json"), origin.clone())
        .await
        .expect("device pool");
    let up = crate::upstream::UpstreamClient::with_mock_origin(
        pool.clone(),
        crate::sign::Manager::new(),
        origin,
    )
    .expect("upstream client");
    Ctx {
        up: Arc::new(up),
        pool,
        cfg: Arc::new(crate::config::Config::default()),
        src_dir: dir.to_string_lossy().into_owned(),
        filters: Arc::new(crate::filter::FilterManager::default()),
    }
}

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

#[tokio::test]
async fn rejects_a_body_over_the_callers_cap() {
    let (port, server) = serve_once(vec![b'x'; 4096]).await;
    let dir = temp_dir("unsigned-cap");
    let ctx = test_ctx(format!("http://127.0.0.1:{port}"), &dir).await;

    // The mock origin rewrites this absolute URL onto the local server.
    let got = unsigned_get(
        &ctx,
        "https://example.invalid/video_model",
        UA_WINDOWS_BROWSER,
        1024,
    )
    .await;
    assert!(got.is_none(), "a 4 KiB body must be refused by a 1 KiB cap");
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn returns_a_body_within_the_cap() {
    let (port, server) = serve_once(b"{\"ok\":true}".to_vec()).await;
    let dir = temp_dir("unsigned-cap-ok");
    let ctx = test_ctx(format!("http://127.0.0.1:{port}"), &dir).await;

    let body = unsigned_get(
        &ctx,
        "https://example.invalid/video_model",
        UA_WINDOWS_BROWSER,
        1024,
    )
    .await
    .expect("body within the cap");
    assert_eq!(body, b"{\"ok\":true}");
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}
