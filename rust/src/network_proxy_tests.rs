//! Runs policy mutations in a dedicated test process so parallel tests keep direct networking.
#[cfg(target_os = "windows")]
use std::io::{Read, Write};
#[cfg(target_os = "windows")]
use std::net::TcpListener;
#[cfg(target_os = "windows")]
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};
#[cfg(target_os = "windows")]
use std::time::Duration;

#[cfg(target_os = "windows")]
struct Server {
    url: String,
    hits: Arc<AtomicUsize>,
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
#[cfg(target_os = "windows")]
impl Server {
    fn new(body: &'static str, proxy: bool) -> Self {
        Self::serve(body, proxy, None)
    }
    fn socks(body: &'static str, remote_dns: bool) -> Self {
        Self::serve(body, false, Some(remote_dns))
    }
    fn serve(body: &'static str, proxy: bool, socks: Option<bool>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let hits = Arc::new(AtomicUsize::new(0));
        let count = hits.clone();
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = std::thread::spawn(move || {
            while !stopping.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        if let Some(remote_dns) = socks {
                            let mut greeting = [0; 3];
                            stream.read_exact(&mut greeting).unwrap();
                            assert_eq!(greeting, [5, 1, 0]);
                            stream.write_all(&[5, 0]).unwrap();
                            let mut connect = [0; 4];
                            stream.read_exact(&mut connect).unwrap();
                            assert_eq!(&connect[..3], &[5, 1, 0]);
                            assert_eq!(connect[3], if remote_dns { 3 } else { 1 });
                            let length = if connect[3] == 3 {
                                let mut length = [0];
                                stream.read_exact(&mut length).unwrap();
                                usize::from(length[0])
                            } else {
                                4
                            };
                            let mut address = vec![0; length + 2];
                            stream.read_exact(&mut address).unwrap();
                            if remote_dns {
                                assert_eq!(&address[..length], b"unresolvable.invalid");
                            }
                            stream
                                .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 80])
                                .unwrap();
                        }
                        let mut request = Vec::new();
                        let mut byte = [0];
                        while stream.read_exact(&mut byte).is_ok() {
                            request.push(byte[0]);
                            if request.ends_with(b"\r\n\r\n") {
                                break;
                            }
                        }
                        let request = String::from_utf8_lossy(&request);
                        if request.is_empty() {
                            continue;
                        }
                        if proxy {
                            assert!(request.starts_with("GET http://"), "{request}");
                        }
                        count.fetch_add(1, Ordering::SeqCst);
                        let response = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                        stream.write_all(response.as_bytes()).unwrap();
                        stream.shutdown(std::net::Shutdown::Write).unwrap();
                        let mut drain = [0; 1024];
                        while stream.read(&mut drain).is_ok_and(|n| n > 0) {}
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(2))
                    }
                    Err(e) => panic!("accept: {e}"),
                }
            }
        });
        Self {
            url: format!("http://{addr}"),
            hits,
            stop,
            thread: Some(thread),
        }
    }
}
#[cfg(target_os = "windows")]
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = self.thread.take().unwrap().join();
    }
}

#[cfg(target_os = "windows")]
fn run<F: std::future::Future>(f: F) -> F::Output {
    thread_local! {
        static RUNTIME: tokio::runtime::Runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    }
    RUNTIME.with(|runtime| runtime.block_on(f))
}

#[cfg(target_os = "windows")]
fn restart(root: &std::path::Path, enabled: bool, url: &str) -> Result<String, String> {
    restart_config(
        root,
        serde_json::json!({"network_proxy":{"enabled":enabled,"url":url}}),
    )
}

#[cfg(target_os = "windows")]
fn restart_config(root: &std::path::Path, value: serde_json::Value) -> Result<String, String> {
    let config = root.join("config.json");
    std::fs::write(&config, value.to_string()).unwrap();
    run(async {
        crate::api::shutdown().await.unwrap();
        crate::api::init(
            config.to_string_lossy().into_owned(),
            root.join("pool.json").to_string_lossy().into_owned(),
            root.join("filter.json").to_string_lossy().into_owned(),
            root.to_string_lossy().into_owned(),
            0,
            false,
            "http://127.0.0.1:9".into(),
        )
        .await
    })
}

#[cfg(target_os = "windows")]
fn fetch(url: &str) -> Vec<u8> {
    let http = crate::upstream::HttpTransport::new(5).unwrap();
    run(http.request("GET", url, &[], None, None)).unwrap().body
}

#[cfg(target_os = "windows")]
fn assert_media(root: &std::path::Path, url: &str, expected: &[u8]) {
    let path = root.join("video.part");
    run(crate::endpoints::video::stream_download_to_file_with_cap(
        url, "test", &path, 1024,
    ))
    .unwrap();
    assert_eq!(
        std::fs::read(&path).unwrap(),
        expected,
        "streaming singleton must use current policy"
    );
    #[cfg(target_os = "windows")]
    {
        let client = crate::desktop_fetch::shared_client().unwrap();
        assert_eq!(
            client
                .get(url)
                .timeout(Duration::from_secs(5))
                .send()
                .unwrap()
                .bytes()
                .unwrap()
                .as_ref(),
            expected,
            "desktop singleton must use current policy"
        );
    }
}

#[cfg(not(target_os = "windows"))]
#[test]
fn non_windows_ignores_proxy_configuration() {
    let invalid = crate::config::NetworkProxy {
        enabled: true,
        url: "not a proxy URL".into(),
    };
    assert!(crate::network::apply(&invalid).is_ok());
}

#[test]
fn proxy_url_contract() {
    use crate::config::NetworkProxy;
    for url in [
        "http://localhost:80",
        "https://localhost:443/",
        "socks5://127.0.0.1:1080",
        "socks5h://[::1]:1080",
    ] {
        assert!(
            NetworkProxy {
                enabled: true,
                url: url.into()
            }
            .validate()
            .is_ok(),
            "valid URL rejected: {url}"
        );
    }
    for url in [
        "http://@localhost:80",
        "http://user@localhost:80",
        "http://:secret@localhost:80",
        "http://localhost:0",
        "http://localhost:65536",
        "http://[::1]",
        "http://localhost:80/#fragment",
        " https://localhost:443",
    ] {
        let err = NetworkProxy {
            enabled: true,
            url: url.into(),
        }
        .validate()
        .unwrap_err();
        assert!(
            !err.contains("secret"),
            "validation must never echo credentials"
        );
    }
    assert!(NetworkProxy {
        enabled: false,
        url: "stale disabled setting".into()
    }
    .validate()
    .unwrap()
    .is_none());
}

#[test]
fn proxy_url_rejects_all_whitespace_before_normalization() {
    use crate::config::NetworkProxy;
    for url in [
        "http://local\thost:8080",
        "http://local\nhost:8080",
        "http://local\rhost:8080",
        "http://localhost:8080/\t",
        "http://localhost:8080/\n",
        "http://localhost:8080/\u{00a0}",
        "http://localhost:8080/\u{2003}",
    ] {
        assert!(
            NetworkProxy {
                enabled: true,
                url: url.into()
            }
            .validate()
            .is_err(),
            "whitespace accepted: {url:?}"
        );
    }
}

#[test]
fn proxy_url_rejects_percent_escaped_hosts() {
    use crate::config::NetworkProxy;
    for url in [
        "http://%6cocalhost:8080",
        "https://local%68ost:443",
        "socks5://%31%32%37.0.0.1:1080",
        "socks5h://[fe80::1%25eth0]:1080",
    ] {
        assert!(
            NetworkProxy {
                enabled: true,
                url: url.into()
            }
            .validate()
            .is_err(),
            "escaped host accepted: {url}"
        );
    }
}

#[cfg(target_os = "windows")]
#[test]
fn unified_network_policy() {
    const CHILD: &str = "FQAPP_PROXY_TEST_CHILD";
    if std::env::var_os(CHILD).is_none() {
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "network_proxy_tests::unified_network_policy",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .status()
            .unwrap();
        assert!(status.success(), "isolated network policy test failed");
        return;
    }
    let root = std::env::temp_dir().join(format!("fqapp-proxy-test-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let origin = Server::new("origin", false);
    let first_proxy = Server::new("proxy-one", true);
    let second_proxy = Server::new("proxy-two", true);
    // A loopback destination is intentionally covered: explicit proxies must override NO_PROXY.
    for name in [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
    ] {
        std::env::remove_var(name);
    }
    std::env::set_var("NO_PROXY", "*");
    restart(&root, true, &first_proxy.url).unwrap();
    assert_eq!(
        fetch(&origin.url),
        b"proxy-one",
        "configured proxy must carry upstream requests"
    );
    assert_media(&root, &origin.url, b"proxy-one");
    let first_account = crate::upstream::http::account_transport().unwrap();
    assert_eq!(
        run(first_account.request("GET", &origin.url, &[], None, None))
            .unwrap()
            .body,
        b"proxy-one"
    );
    restart(&root, true, &second_proxy.url).unwrap();
    let account = crate::upstream::http::account_transport().unwrap();
    assert_eq!(
        run(account.request("GET", &origin.url, &[], None, None))
            .unwrap()
            .body,
        b"proxy-two",
        "account singleton must refresh after restart"
    );
    assert_eq!(fetch(&origin.url), b"proxy-two");
    assert_media(&root, &origin.url, b"proxy-two");
    restart(&root, false, "").unwrap();
    std::env::set_var("HTTP_PROXY", &first_proxy.url);
    std::env::set_var("HTTPS_PROXY", &first_proxy.url);
    std::env::set_var("ALL_PROXY", &first_proxy.url);
    std::env::remove_var("NO_PROXY");
    assert_eq!(
        fetch(&origin.url),
        b"origin",
        "direct must ignore environment proxies"
    );
    assert_media(&root, &origin.url, b"origin");
    assert_eq!(
        run(crate::upstream::http::account_transport().unwrap().request(
            "GET",
            &origin.url,
            &[],
            None,
            None
        ))
        .unwrap()
        .body,
        b"origin"
    );
    let unused = TcpListener::bind("127.0.0.1:0").unwrap();
    let dead_proxy = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    restart(&root, true, &dead_proxy).unwrap();
    let before = origin.hits.load(Ordering::SeqCst);
    let http = crate::upstream::HttpTransport::new(1).unwrap();
    assert!(
        run(http.request("GET", &origin.url, &[], None, None)).is_err(),
        "proxy errors must propagate"
    );
    assert!(
        run(crate::upstream::http::account_transport().unwrap().request(
            "GET",
            &origin.url,
            &[],
            None,
            Some(Duration::from_secs(1))
        ))
        .is_err()
    );
    assert!(
        run(crate::endpoints::video::stream_download_to_file_with_cap(
            &origin.url,
            "test",
            &root.join("failed.part"),
            1024
        ))
        .is_err()
    );
    #[cfg(target_os = "windows")]
    assert!(crate::desktop_fetch::shared_client()
        .unwrap()
        .get(&origin.url)
        .timeout(Duration::from_secs(1))
        .send()
        .is_err());
    assert_eq!(
        origin.hits.load(Ordering::SeqCst),
        before,
        "proxy failure must never fallback to direct"
    );
    let socks = Server::socks("socks-local", false);
    restart(&root, true, &socks.url.replacen("http:", "socks5:", 1)).unwrap();
    assert_eq!(fetch(&origin.url), b"socks-local");
    assert_media(&root, &origin.url, b"socks-local");
    let socks_remote = Server::socks("socks-remote", true);
    restart(
        &root,
        true,
        &socks_remote.url.replacen("http:", "socks5h:", 1),
    )
    .unwrap();
    assert_eq!(
        fetch("http://unresolvable.invalid:8080/path"),
        b"socks-remote",
        "socks5h must delegate DNS to proxy"
    );
    assert_media(
        &root,
        "http://unresolvable.invalid:8080/path",
        b"socks-remote",
    );
    for bad in [
        "http://user:placeholder@localhost:8080",
        "http://localhost",
        "ftp://localhost:21",
        "socks5://localhost",
        "http://localhost:80/path",
        "http://localhost:80?x=1",
    ] {
        assert!(
            restart(&root, true, bad).is_err(),
            "invalid proxy accepted: {bad}"
        );
    }
    restart_config(&root, serde_json::json!({})).unwrap();
    assert_eq!(
        fetch(&origin.url),
        b"origin",
        "old configs without network_proxy default to direct"
    );
    assert_media(&root, &origin.url, b"origin");
    run(crate::api::shutdown()).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
}
