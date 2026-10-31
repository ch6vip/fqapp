use super::super::*;

/// P1-6: manga images (`img_*`) must count toward the same `src_dir`
/// budget as videos and be evicted oldest-first; in-flight and
/// unrelated files must never be deleted.
#[test]
fn src_cache_prune_evicts_oldest_manga_images_too() {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-prune-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let write_at = |name: &str, size: usize, secs: u64| {
        let path = dir.join(name);
        std::fs::write(&path, vec![b'x'; size]).expect("write cache file");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .expect("open cache file")
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs))
            .expect("set mtime");
        path
    };
    let old_video = write_at("old.mp4", 60, 50);
    let old_image = write_at("img_old.png", 60, 100);
    let new_image = write_at("img_new.png", 60, 200);
    let in_flight = write_at("img_tmp.png.part", 60, 10);
    let unrelated = write_at("notes.txt", 60, 10);

    // Total counted = 180 (video + 2 images); budget 100 forces eviction
    // of the oldest first: old video, then old image. The kept (newest)
    // image, the in-flight part file, and the unrelated file survive.
    prune_src_cache_with_budget(&dir.to_string_lossy(), &new_image, 100);

    assert!(!old_video.exists(), "oldest video must be evicted");
    assert!(!old_image.exists(), "oldest manga image must be evicted");
    assert!(new_image.exists(), "kept image must survive");
    assert!(in_flight.exists(), "in-flight .part must never be deleted");
    assert!(unrelated.exists(), "unrelated files must never be deleted");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Eviction now runs off the request path, once at a time. While a pass
/// holds the lock a newly scheduled one must skip instead of queueing, and
/// once the lock is free the next request's pass evicts.
#[tokio::test]
async fn scheduled_prune_runs_in_the_background_and_never_overlaps() {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-prune-bg-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let write_at = |name: &str, secs: u64| {
        let path = dir.join(name);
        std::fs::write(&path, vec![b'x'; 60]).expect("write cache file");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .expect("open cache file")
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs))
            .expect("set mtime");
        path
    };
    let old_video = write_at("old.mp4", 50);
    let new_video = write_at("new.mp4", 200);
    let src_dir = dir.to_string_lossy().into_owned();

    // Hold the pass lock: a scheduled pass must skip while one is
    // already running instead of queueing behind it.
    let guard = PRUNE_LOCK.lock().await;
    schedule_prune_src_cache_with_budget(&src_dir, new_video.clone(), 100);
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
    assert!(
        old_video.exists(),
        "a scheduled pass must not run while one is already running"
    );
    drop(guard);

    // Once the lock is free the next scheduled pass evicts. Retry because
    // other tests in this binary share the same pass lock.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while old_video.exists() && tokio::time::Instant::now() < deadline {
        schedule_prune_src_cache_with_budget(&src_dir, new_video.clone(), 100);
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(
        !old_video.exists(),
        "the scheduled pass must evict the oldest file"
    );
    assert!(new_video.exists(), "the kept file must survive");
    let _ = std::fs::remove_dir_all(&dir);
}

/// P1-9: the download must stream chunk by chunk (never hold the whole
/// file in memory) and enforce the per-file cap, both from an
/// advertised `Content-Length` and from the running byte count.
/// A local TCP server stands in for the upstream host.
async fn serve_once(body: Vec<u8>, advertised: Option<u64>) -> (u16, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind test server");
    let port = listener.local_addr().expect("test server addr").port();
    let handle = tokio::spawn(async move {
        if let Ok((mut socket, _)) = listener.accept().await {
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            let header = match advertised {
                Some(len) => {
                    format!("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {len}\r\n\r\n")
                }
                None => "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_string(),
            };
            let _ = socket.write_all(header.as_bytes()).await;
            let _ = socket.write_all(&body).await;
            let _ = socket.shutdown().await;
        }
    });
    (port, handle)
}

fn ensure_test_crypto_provider() {
    // The streaming client is built with rustls-no-provider, so it
    // needs the process-wide default provider the upstream transport
    // normally installs at startup. Mirror `upstream/http.rs`.
    let _ = rustls::crypto::ring::default_provider().install_default();
}

#[tokio::test]
async fn stream_download_writes_body_without_whole_file_buffer() {
    ensure_test_crypto_provider();
    let body: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
    let (port, server) = serve_once(body.clone(), Some(body.len() as u64)).await;
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let part = dir.join("ep.mp4.part");
    let url = format!("http://127.0.0.1:{port}/ep.mp4");
    let total = stream_download_to_file(&url, UA_WINDOWS_BROWSER, &part)
        .await
        .expect("stream download");
    assert_eq!(total, body.len() as u64);
    assert_eq!(std::fs::read(&part).expect("read part"), body);
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn stream_download_rejects_lying_content_length() {
    ensure_test_crypto_provider();
    let body = vec![b'x'; 64];
    let (port, server) = serve_once(body, Some(MAX_VIDEO_DOWNLOAD_BYTES + 1)).await;
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-cap-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let part = dir.join("ep.mp4.part");
    let url = format!("http://127.0.0.1:{port}/ep.mp4");
    let err = stream_download_to_file(&url, UA_WINDOWS_BROWSER, &part)
        .await
        .expect_err("lying Content-Length must be rejected");
    assert!(err.contains("content-length"), "unexpected error: {err}");
    assert!(
        !part.exists(),
        "no file must be created on precheck failure"
    );
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn stream_download_enforces_cap_from_running_total() {
    ensure_test_crypto_provider();
    // No advertised length: the running byte count must stop the
    // download. A small cap keeps the test fast.
    let body = vec![b'y'; 100];
    let (port, server) = serve_once(body, None).await;
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-total-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let part = dir.join("ep.mp4.part");
    let url = format!("http://127.0.0.1:{port}/ep.mp4");
    // Exercise the same loop with a small cap via the test-only seam.
    let err = stream_download_to_file_with_cap(&url, UA_WINDOWS_BROWSER, &part, 10)
        .await
        .expect_err("stream past the cap must be rejected");
    assert!(err.contains("exceeds cap"), "unexpected error: {err}");
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}
