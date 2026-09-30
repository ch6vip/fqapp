//! Shared host-test scaffolding: temporary runtime directories, a real
//! dispatcher `Server`, a real loopback adapter, and a scripted mock upstream.
//!
//! Nothing here touches the network, a device, or the real device pool.

#![allow(dead_code)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response as AxumResponse};
use axum::Router;
use fqapi_core::config::Config;
use fqapi_core::device::DevicePool;
use fqapi_core::endpoints::{Ctx, Server};
use fqapi_core::filter::FilterManager;
use fqapi_core::sign::Manager;
use fqapi_core::upstream::UpstreamClient;

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A temporary directory removed on drop.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(tag: &str) -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path =
            std::env::temp_dir().join(format!("-core-test-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create temp dir");
        TempDir { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, rel: &str) -> PathBuf {
        self.path.join(rel)
    }

    pub fn write(&self, rel: &str, contents: &str) -> PathBuf {
        let full = self.join(rel);
        if let Some(parent) = full.parent() {
            std::fs::create_dir_all(parent).expect("create parent");
        }
        std::fs::write(&full, contents).expect("write test file");
        full
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// Builds a real dispatcher `Server` over a fresh runtime directory.
///
/// `mock_origin` redirects every upstream call to a local mock server.
/// `web` / `src` are relative file contents written under the runtime root.
pub async fn build_server(
    dir: &TempDir,
    mock_origin: Option<String>,
    web: &[(&str, &str)],
    src: &[(&str, &str)],
    pool_json: &str,
) -> Arc<Server> {
    build_server_with_config(
        dir,
        mock_origin,
        web,
        src,
        pool_json,
        r#"{"algorithm_type":"8404","port":0,"anti_crawler":{"enabled":false,"redirect_url":""}}"#,
    )
    .await
}

/// [`build_server`] with an explicit `config.json` body.
pub async fn build_server_with_config(
    dir: &TempDir,
    mock_origin: Option<String>,
    web: &[(&str, &str)],
    src: &[(&str, &str)],
    pool_json: &str,
    config_json: &str,
) -> Arc<Server> {
    let root = dir.path().to_path_buf();
    std::fs::create_dir_all(root.join("src")).expect("src dir");
    std::fs::create_dir_all(root.join("web")).expect("web dir");

    let config_path = dir.write("config/config.json", config_json);
    let pool_path = dir.write("config/device_pool.json", pool_json);
    // A missing filter.json yields a no-op manager, matching the Go behaviour.
    let filter_path = dir.join("config/filter.json");

    for (rel, contents) in web {
        dir.write(&format!("web/{rel}"), contents);
    }
    for (rel, contents) in src {
        dir.write(&format!("src/{rel}"), contents);
    }

    let cfg: Config =
        serde_json::from_str(&std::fs::read_to_string(&config_path).unwrap()).expect("config json");
    let pool = match mock_origin.clone() {
        Some(origin) => DevicePool::with_mock_origin(&pool_path, origin)
            .await
            .expect("pool"),
        None => DevicePool::new(&pool_path).await.expect("pool"),
    };
    let signer = Manager::new();
    let up = match mock_origin {
        Some(origin) => {
            UpstreamClient::with_mock_origin(pool.clone(), signer, origin).expect("upstream client")
        }
        None => UpstreamClient::new(pool.clone(), signer).expect("upstream client"),
    };
    let filters = Arc::new(
        FilterManager::load_with_base(&filter_path.to_string_lossy(), &root.to_string_lossy())
            .expect("filters"),
    );

    Arc::new(Server::new(Arc::new(Ctx {
        up: Arc::new(up),
        pool,
        cfg: Arc::new(cfg),
        src_dir: root.join("src").to_string_lossy().into_owned(),
        web_dir: root.join("web").to_string_lossy().into_owned(),
        filters,
    })))
}

/// A device pool JSON with `count` devices, in the on-disk Go-compatible shape.
pub fn pool_json(count: usize) -> String {
    let devices: Vec<serde_json::Value> = (0..count)
        .map(|i| {
            serde_json::json!({
                "device_id": format!("{i:016}"),
                "install_id": format!("{}", 9_000_000_000_000_000_000u64 + i as u64),
                "secret_key": format!("{:032x}", i),
                "platform": "android",
                "status": "active",
                "created_time": "2026-01-01 00:00:00",
                "last_used": format!("2026-01-01 00:00:{i:02}"),
                "use_count": i,
                "cdid": format!("cdid-{i}"),
            })
        })
        .collect();
    serde_json::json!({ "android": devices, "last_update": "2026-01-01 00:00:00" }).to_string()
}

/// Starts the real loopback adapter on an ephemeral port.
pub async fn start_loopback(server: Arc<Server>) -> (u16, tokio::task::JoinHandle<()>) {
    let handle = fqapi_core::server::serve(server, 0)
        .await
        .expect("loopback adapter");
    (handle.port, handle.task)
}

// --- Mock upstream ---------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Recorded {
    pub method: String,
    pub path: String,
    pub query: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Recorded {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone)]
pub struct MockReply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl MockReply {
    pub fn json(body: serde_json::Value) -> Self {
        MockReply {
            status: 200,
            headers: vec![("content-type".to_string(), "application/json".to_string())],
            body: serde_json::to_vec(&body).unwrap_or_default(),
        }
    }

    pub fn status(status: u16) -> Self {
        MockReply {
            status,
            headers: Vec::new(),
            body: Vec::new(),
        }
    }
}

type Responder = Arc<dyn Fn(&Recorded) -> MockReply + Send + Sync>;

pub struct MockUpstream {
    pub origin: String,
    pub recorded: Arc<Mutex<Vec<Recorded>>>,
    task: tokio::task::JoinHandle<()>,
}

impl MockUpstream {
    pub async fn start<F>(respond: F) -> Self
    where
        F: Fn(&Recorded) -> MockReply + Send + Sync + 'static,
    {
        let recorded: Arc<Mutex<Vec<Recorded>>> = Arc::new(Mutex::new(Vec::new()));
        let responder: Responder = Arc::new(respond);

        let state = MockHandlerState {
            recorded: recorded.clone(),
            responder,
        };

        let app = Router::new().fallback(mock_handler).with_state(state);
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind mock");
        let port = listener.local_addr().expect("addr").port();
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        MockUpstream {
            origin: format!("http://127.0.0.1:{port}"),
            recorded,
            task,
        }
    }

    pub fn requests(&self) -> Vec<Recorded> {
        self.recorded.lock().map(|r| r.clone()).unwrap_or_default()
    }

    pub fn last_request(&self) -> Option<Recorded> {
        self.requests().pop()
    }

    pub fn shutdown(&self) {
        self.task.abort();
    }
}

impl Drop for MockUpstream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn mock_handler(
    State(state): State<MockHandlerState>,
    req: axum::extract::Request,
) -> AxumResponse {
    let method = req.method().to_string();
    let uri = req.uri().clone();
    let headers: Vec<(String, String)> = req
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).into_owned(),
            )
        })
        .collect();
    let body = axum::body::to_bytes(req.into_body(), 8 * 1024 * 1024)
        .await
        .unwrap_or_default()
        .to_vec();
    let recorded = Recorded {
        method,
        path: uri.path().to_string(),
        query: uri.query().unwrap_or("").to_string(),
        headers,
        body,
    };
    if let Ok(mut log) = state.recorded.lock() {
        log.push(recorded.clone());
    }
    let reply = (state.responder)(&recorded);

    let mut builder = AxumResponse::builder()
        .status(StatusCode::from_u16(reply.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR));
    for (name, value) in &reply.headers {
        if let (Ok(n), Ok(v)) = (
            axum::http::HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            builder = builder.header(n, v);
        }
    }
    builder
        .body(Body::from(reply.body))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

#[derive(Clone)]
pub struct MockHandlerState {
    recorded: Arc<Mutex<Vec<Recorded>>>,
    responder: Responder,
}

/// Convenience: parse the recorded query into a map.
pub fn query_map(query: &str) -> HashMap<String, String> {
    url::form_urlencoded::parse(query.as_bytes())
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect()
}
