//! flutter_rust_bridge surface - the public entry point of the Rust core.
//!
//! Architecture decision and consequences:
//! .agents/notes/implemented/architecture/2026-09-23-rust-native-core-migration.md
//! Behaviour contract: docs/migration/rust-migration-contracts.md
//!
//! Flutter calls [request] for every backend call; the loopback HTTP adapter
//! (`server.rs`) serves the built-in Web UI and `/src/*` resources from the
//! same dispatcher. Requests carry an id so they can be cancelled: cancelling
//! drops the in-flight dispatch future, which tears down the awaiting reqwest
//! call, any retry backoff and any not-yet-submitted write. A write that the
//! filesystem has already accepted is not rolled back - Tokio file I/O is not
//! cancellable once submitted - so cancellation is a "stop the work", not a
//! transaction.

use std::collections::HashMap;
use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use once_cell::sync::Lazy;
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::device::DevicePool;
use crate::dispatch::Response;
use crate::endpoints::{Ctx, Server};
use crate::filter::FilterManager;
use crate::sign::Manager;
use crate::upstream::UpstreamClient;

#[derive(Debug, Clone)]
pub struct BridgeResponse {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
}

struct Core {
    generation: u64,
    server: Arc<Server>,
    port: u16,
    token: String,
    task: Option<tokio::task::JoinHandle<()>>,
}

static CORE: Lazy<RwLock<Option<Arc<Core>>>> = Lazy::new(|| RwLock::new(None));
/// Serializes the whole initialization and shutdown state machine. Concurrent
/// `init` callers therefore share one startup and all observe `"running"`
/// instead of racing for the listening port.
static INIT_LOCK: Lazy<tokio::sync::Mutex<()>> = Lazy::new(|| tokio::sync::Mutex::new(()));
static GENERATION: AtomicU64 = AtomicU64::new(0);
/// In-flight calls keyed by request id. Each entry remembers the core
/// generation it belongs to, so cleanup after a restart can only remove its own
/// entry and never a newer core's registration.
static INFLIGHT: Lazy<Mutex<HashMap<String, (u64, CancellationToken)>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
/// Ids cancelled before their `request` registered. Bounded so a caller that
/// cancels junk ids cannot grow memory without limit.
static PRE_CANCELLED: Lazy<Mutex<Vec<String>>> = Lazy::new(|| Mutex::new(Vec::new()));
const PRE_CANCELLED_LIMIT: usize = 256;

/// Backend core version.
pub fn version() -> String {
    format!("fqapi_core {}", env!("CARGO_PKG_VERSION"))
}

/// Resolves the runtime root (contains src/, web/, filters/).
fn resolve_runtime_dir(config_path: &str, explicit: &str) -> PathBuf {
    if !explicit.is_empty() {
        return std::fs::canonicalize(explicit).unwrap_or_else(|_| PathBuf::from(explicit));
    }
    let abs = std::fs::canonicalize(config_path).unwrap_or_else(|_| PathBuf::from(config_path));
    let parent = abs.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    if parent
        .file_name()
        .map(|n| n.eq_ignore_ascii_case("config"))
        .unwrap_or(false)
    {
        return parent.parent().map(|p| p.to_path_buf()).unwrap_or(parent);
    }
    parent
}

/// Idempotent initialization. A second call while running returns `"running"`.
///
/// `mock_upstream_origin` is empty in the shipping app. The host integration
/// test sets it to a local mock server so the real Dart -> FRB -> Rust path can
/// be exercised offline, without touching the network or a real device pool.
pub async fn init(
    config_path: String,
    pool_path: String,
    filter_path: String,
    runtime_dir: String,
    port: u16,
    mock_upstream_origin: String,
) -> Result<String, String> {
    // The shipping core has no console, and an Android app cannot read its own
    // logcat (READ_LOGS is a system permission), so logs go to a rotating file
    // beside the runtime files *and* to logcat. Desktop/test builds never
    // install a logger, where the `log` macros compile to no-ops.
    #[cfg(target_os = "android")]
    {
        crate::core_log::install(&resolve_runtime_dir(&config_path, &runtime_dir));
        log::info!("core init: port={port} config={config_path}");
    }
    let mock = if mock_upstream_origin.trim().is_empty() {
        None
    } else {
        Some(mock_upstream_origin)
    };
    init_core(config_path, pool_path, filter_path, runtime_dir, port, mock).await
}

/// Initialization with an optional upstream origin override. The public
/// `init` passes `None` for the shipping app; host integration tests redirect
/// every upstream call to a local mock server through this seam.
pub(crate) async fn init_core(
    config_path: String,
    pool_path: String,
    filter_path: String,
    runtime_dir: String,
    port: u16,
    mock_origin: Option<String>,
) -> Result<String, String> {
    let _guard = INIT_LOCK.lock().await;
    {
        let guard = CORE.read().await;
        if guard.is_some() {
            return Ok("running".to_string());
        }
    }

    let cfg = Arc::new(Config::load(&config_path)?);
    let root = resolve_runtime_dir(&config_path, &runtime_dir);
    let src_dir = root.join("src");
    let _ = std::fs::create_dir_all(&src_dir);
    let web_dir = root.join("web");

    let pool = match mock_origin.as_ref() {
        Some(origin) => DevicePool::with_mock_origin(&pool_path, origin.clone()).await?,
        None => DevicePool::new(&pool_path).await?,
    };
    let signer = Manager::new();
    let up = Arc::new(match mock_origin {
        Some(origin) => UpstreamClient::with_mock_origin(pool.clone(), signer, origin)?,
        None => UpstreamClient::new(pool.clone(), signer)?,
    });
    let filters = Arc::new(FilterManager::load_with_base(
        &filter_path,
        &root.to_string_lossy(),
    )?);

    let ctx = Arc::new(Ctx {
        up,
        pool,
        cfg: cfg.clone(),
        src_dir: src_dir.to_string_lossy().into_owned(),
        web_dir: web_dir.to_string_lossy().into_owned(),
        filters,
    });
    let server = Arc::new(Server::new(ctx));

    // `port == 0` binds an ephemeral loopback port (host tests and any caller
    // that does not care which port is used); the Flutter transport passes the
    // configured 8080 explicitly. The loopback adapter is always part of the
    // core because resource URLs (`/src/...`) depend on it.
    let _ = cfg.port;
    let (actual_port, token, task) = match crate::server::serve(server.clone(), port).await {
        Ok(handle) => (handle.port, handle.token, Some(handle.task)),
        Err(e) => return Err(e),
    };

    // The generation is read after the resource is fully built, so a stale
    // shutdown (which takes the same lock and bumps the counter) can never
    // retire this core.
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    let mut guard = CORE.write().await;
    *guard = Some(Arc::new(Core {
        generation,
        server,
        port: actual_port,
        token,
        task,
    }));
    Ok("running".to_string())
}

/// Stops the loopback adapter and drops the core.
///
/// Waits for an in-flight initialization first, so a shutdown issued during
/// `init` tears down the core that `init` just created rather than leaving it
/// running. Safe to call repeatedly.
pub async fn shutdown() -> Result<(), String> {
    let _guard = INIT_LOCK.lock().await;
    GENERATION.fetch_add(1, Ordering::SeqCst);
    let core = { CORE.write().await.take() };
    if let Some(core) = core {
        if let Some(task) = &core.task {
            task.abort();
        }
        // Ownership hand-off. Awaiting this is what makes the guarantee hold: a
        // commit that already started finishes its rename first, and every later
        // one is refused, so shutdown cannot return while an old write is still
        // able to land.
        core.server.ctx.pool.retire().await;
    }
    // Cancel every in-flight call so a late result cannot be published.
    let tokens: Vec<CancellationToken> = match INFLIGHT.lock() {
        Ok(mut m) => m.drain().map(|(_, (_, t))| t).collect(),
        Err(_) => Vec::new(),
    };
    for token in tokens {
        token.cancel();
    }
    Ok(())
}

/// `"running"`, `"starting"` or `"failed: <message>"` - the same contract as
/// the Kotlin/JNI bridge this replaces.
pub async fn status() -> String {
    let guard = CORE.read().await;
    match guard.as_ref() {
        Some(_) => "running".to_string(),
        None => "starting".to_string(),
    }
}

/// Base URL of the loopback adapter, for resource URLs (`absoluteUrl`).
pub async fn base_url() -> String {
    let guard = CORE.read().await;
    match guard.as_ref() {
        Some(core) if core.port != 0 => format!("http://127.0.0.1:{}", core.port),
        _ => String::new(),
    }
}
/// Per-launch capability of the loopback adapter.
///
/// Every request the adapter accepts must carry it: as a `/_session/<cap>`
/// path prefix, an `Authorization: Bearer` header, or the session cookie the
/// entry URL sets. `base_url()` deliberately stays capability-free - the same
/// value is the FFI path root, and FFI calls never cross the socket. URLs
/// handed to HTTP clients instead (`/src/...`) must carry the prefix.
pub async fn session_capability() -> String {
    let guard = CORE.read().await;
    match guard.as_ref() {
        Some(core) => core.token.clone(),
        None => String::new(),
    }
}

/// Generation of the live core (0 when stopped). Used by the host tests to
/// prove that a stale shutdown or request cleanup cannot affect a newer core;
/// it is test-only so it never reaches the bridge or the release build.
#[cfg(test)]
pub(crate) async fn core_generation() -> u64 {
    let guard = CORE.read().await;
    match guard.as_ref() {
        Some(core) => core.generation,
        None => 0,
    }
}

/// The single entry point for every backend call from Flutter.
///
/// `timeout_ms <= 0` means "no deadline". A cancelled or timed-out call drops
/// the dispatch future, which cancels the awaiting upstream request.
pub async fn request(
    request_id: String,
    method: String,
    path: String,
    query: String,
    body: Vec<u8>,
    timeout_ms: i64,
) -> Result<BridgeResponse, String> {
    let (server, generation) = {
        let guard = CORE.read().await;
        match guard.as_ref() {
            Some(core) => (core.server.clone(), core.generation),
            None => return Err("backend not initialized".to_string()),
        }
    };

    // A cancel that arrived before this call registered is honoured here.
    if !request_id.is_empty() && take_pre_cancelled(&request_id) {
        return Ok(cancelled_response());
    }

    let token = CancellationToken::new();
    if !request_id.is_empty() {
        if let Ok(mut m) = INFLIGHT.lock() {
            m.insert(request_id.clone(), (generation, token.clone()));
        }
        // Re-check: a cancel racing the insert must not be lost.
        if take_pre_cancelled(&request_id) {
            token.cancel();
        }
    }

    let req = crate::dispatch::Request {
        method: if method.is_empty() {
            "GET".to_string()
        } else {
            method
        },
        path,
        query,
        body,
        headers: Vec::new(),
    };

    let deadline = if timeout_ms > 0 {
        Some(Duration::from_millis(timeout_ms as u64))
    } else {
        None
    };
    let outcome = race_dispatch(&token, deadline, crate::dispatch::dispatch(&server, &req)).await;

    if !request_id.is_empty() {
        release_inflight(&request_id, generation);
    }

    match outcome {
        RaceOutcome::Cancelled => Ok(cancelled_response()),
        RaceOutcome::TimedOut => Ok(timeout_response()),
        RaceOutcome::Done(resp) => {
            let status = resp.status;
            let content_type = resp.content_type.clone();
            let body = resp.into_bytes().await?;
            Ok(BridgeResponse {
                status,
                content_type,
                body,
            })
        }
    }
}

/// Cancels an in-flight `request`. Returns true when a call was registered.
///
/// An unknown id is remembered as pre-cancelled so a cancel that beats the
/// request's own registration still takes effect.
pub fn cancel(request_id: String) -> bool {
    if request_id.is_empty() {
        return false;
    }
    // Cancelling is generation-agnostic: a caller that holds an id wants that
    // call stopped regardless of which core owns it now.
    let existing = match INFLIGHT.lock() {
        Ok(mut m) => m.remove(&request_id),
        Err(_) => None,
    };
    match existing {
        Some((_, token)) => {
            token.cancel();
            true
        }
        None => {
            if let Ok(mut pre) = PRE_CANCELLED.lock() {
                if !pre.contains(&request_id) {
                    if pre.len() >= PRE_CANCELLED_LIMIT {
                        pre.remove(0);
                    }
                    pre.push(request_id);
                }
            }
            false
        }
    }
}

/// Removes the in-flight entry only when it still belongs to `generation`.
///
/// After a shutdown/re-init cycle an old request's cleanup must not touch the
/// registration made by the new core.
fn release_inflight(request_id: &str, generation: u64) {
    if let Ok(mut m) = INFLIGHT.lock() {
        let mine = m
            .get(request_id)
            .map(|(owner, _)| *owner == generation)
            .unwrap_or(false);
        if mine {
            m.remove(request_id);
        }
    }
}

fn take_pre_cancelled(request_id: &str) -> bool {
    match PRE_CANCELLED.lock() {
        Ok(mut pre) => match pre.iter().position(|id| id == request_id) {
            Some(idx) => {
                pre.remove(idx);
                true
            }
            None => false,
        },
        Err(_) => false,
    }
}

fn cancelled_response() -> BridgeResponse {
    BridgeResponse {
        status: 499,
        content_type: "application/json; charset=utf-8".to_string(),
        body: br#"{"success":false,"error":"cancelled"}"#.to_vec(),
    }
}

fn timeout_response() -> BridgeResponse {
    BridgeResponse {
        status: 504,
        content_type: "application/json; charset=utf-8".to_string(),
        body: br#"{"success":false,"error":"timeout"}"#.to_vec(),
    }
}

/// Result of racing one dispatch against its cancellation token and deadline.
#[derive(Debug)]
pub(crate) enum RaceOutcome {
    Done(Response),
    Cancelled,
    TimedOut,
}

/// Races a dispatch future against cancellation and the total deadline.
///
/// Dropping the work future is what makes cancellation real: the awaiting
/// reqwest request, the retry backoff and any not-yet-submitted write are all
/// abandoned with it.
pub(crate) async fn race_dispatch<F>(
    token: &CancellationToken,
    deadline: Option<Duration>,
    work: F,
) -> RaceOutcome
where
    F: Future<Output = Response>,
{
    tokio::pin!(work);
    match deadline {
        Some(limit) => tokio::select! {
            biased;
            _ = token.cancelled() => RaceOutcome::Cancelled,
            r = tokio::time::timeout(limit, &mut work) => match r {
                Ok(resp) => RaceOutcome::Done(resp),
                Err(_) => RaceOutcome::TimedOut,
            },
        },
        None => tokio::select! {
            biased;
            _ = token.cancelled() => RaceOutcome::Cancelled,
            resp = &mut work => RaceOutcome::Done(resp),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_response() -> Response {
        Response::text(200, "text/plain", b"ok".to_vec())
    }

    #[tokio::test]
    async fn race_reports_cancellation_for_a_pending_dispatch() {
        let token = CancellationToken::new();
        let handle = token.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            handle.cancel();
        });
        let outcome = race_dispatch(&token, None, async {
            tokio::time::sleep(Duration::from_secs(30)).await;
            dummy_response()
        })
        .await;
        assert!(matches!(outcome, RaceOutcome::Cancelled));
    }

    #[tokio::test]
    async fn race_reports_timeout_for_a_slow_dispatch() {
        let token = CancellationToken::new();
        let outcome = race_dispatch(&token, Some(Duration::from_millis(10)), async {
            tokio::time::sleep(Duration::from_secs(30)).await;
            dummy_response()
        })
        .await;
        assert!(matches!(outcome, RaceOutcome::TimedOut));
    }

    #[tokio::test]
    async fn race_returns_the_response_when_nothing_intervenes() {
        let token = CancellationToken::new();
        let outcome = race_dispatch(&token, Some(Duration::from_secs(5)), async {
            dummy_response()
        })
        .await;
        match outcome {
            RaceOutcome::Done(resp) => assert_eq!(resp.status, 200),
            other => panic!("unexpected outcome: {other:?}"),
        }
    }

    #[tokio::test]
    async fn cancel_of_an_unregistered_id_is_remembered_and_consumed_once() {
        let _guard = CORE_TEST_LOCK.lock().await;
        let id = "pre-cancel-test-id".to_string();
        assert!(!cancel(id.clone()), "nothing was registered yet");
        assert!(take_pre_cancelled(&id));
        assert!(!take_pre_cancelled(&id), "consumed exactly once");
    }

    #[tokio::test]
    async fn cancel_of_a_registered_id_cancels_its_token() {
        let _guard = CORE_TEST_LOCK.lock().await;
        let token = CancellationToken::new();
        let id = "registered-cancel-test-id".to_string();
        INFLIGHT
            .lock()
            .unwrap()
            .insert(id.clone(), (1, token.clone()));
        assert!(cancel(id.clone()));
        assert!(token.is_cancelled());
    }

    #[tokio::test]
    async fn release_inflight_only_removes_its_own_generation() {
        // INFLIGHT is process-wide, so this must not run next to a test that
        // calls shutdown() (which drains it).
        let _guard = CORE_TEST_LOCK.lock().await;
        let token = CancellationToken::new();
        let id = "generation-owned-id".to_string();
        INFLIGHT.lock().unwrap().insert(id.clone(), (7, token));
        release_inflight(&id, 8);
        assert!(
            INFLIGHT.lock().unwrap().contains_key(&id),
            "cleanup from a newer generation must not remove another core's entry"
        );
        release_inflight(&id, 7);
        assert!(!INFLIGHT.lock().unwrap().contains_key(&id));
    }

    /// A slow local upstream so a request can genuinely be in flight while the
    /// core is shut down and re-initialized.
    async fn slow_mock_upstream(delay: Duration) -> (String, tokio::task::JoinHandle<()>) {
        let app = axum::Router::new().fallback(move |_req: axum::extract::Request| async move {
            tokio::time::sleep(delay).await;
            (
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                r#"{"code":0,"data":{}}"#,
            )
        });
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind mock");
        let port = listener.local_addr().expect("addr").port();
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        (format!("http://127.0.0.1:{port}"), task)
    }

    /// V2: an old request that spans a shutdown/re-init must be cancelled and
    /// must not disturb the new core.
    #[tokio::test]
    async fn a_request_spanning_a_restart_is_cancelled_without_polluting_the_new_core() {
        let _guard = CORE_TEST_LOCK.lock().await;
        let _ = shutdown().await;
        let dir = runtime_dir("span-restart");
        let (origin, mock_task) = slow_mock_upstream(Duration::from_millis(500)).await;

        let (cfg, pool, filter, runtime, port, _) = init_args(&dir);
        init_core(cfg, pool, filter, runtime, port, Some(origin.clone()))
            .await
            .expect("first init");
        let first_generation = core_generation().await;

        let pending = tokio::spawn(request(
            "old-request".to_string(),
            "GET".to_string(),
            "/api/v1/items/7507512821328904729".to_string(),
            String::new(),
            Vec::new(),
            0,
        ));

        // Let the call reach the (slow) upstream, then restart the core.
        tokio::time::sleep(Duration::from_millis(120)).await;
        shutdown().await.expect("shutdown");

        let (cfg, pool, filter, runtime, port, _) = init_args(&dir);
        init_core(cfg, pool, filter, runtime, port, Some(origin))
            .await
            .expect("second init");
        let second_generation = core_generation().await;
        assert!(
            second_generation > first_generation,
            "restart must publish a newer generation ({second_generation} vs {first_generation})"
        );

        let old = pending.await.expect("join").expect("bridge response");
        assert_eq!(
            old.status, 499,
            "the request that spanned the restart must be cancelled, not published"
        );

        assert_eq!(status().await, "running");
        let fresh = request(
            "new-request".to_string(),
            "GET".to_string(),
            "/health".to_string(),
            String::new(),
            Vec::new(),
            0,
        )
        .await
        .expect("the new core serves requests");
        assert_eq!(fresh.status, 200);
        assert!(health_ok(&base_url().await, &session_capability().await).await);

        mock_task.abort();
        shutdown().await.expect("shutdown");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn request_without_a_core_fails_closed() {
        // This asserts on the absence of a core, which is process wide state
        // that the init-based tests in this module set and tear down. Without
        // the same guard they use, one of those can be mid-run in parallel and
        // the request succeeds instead of failing closed.
        let _guard = CORE_TEST_LOCK.lock().await;
        let _ = shutdown().await;
        let err = request(
            "no-core".to_string(),
            "GET".to_string(),
            "/health".to_string(),
            String::new(),
            Vec::new(),
            0,
        )
        .await
        .unwrap_err();
        assert_eq!(err, "backend not initialized");
    }

    // --- F3: initialization state machine ---------------------------------

    static CORE_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    fn runtime_dir(tag: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!(
            "fqapi-core-init-{tag}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(path.join("config")).expect("config dir");
        std::fs::write(
            path.join("config/config.json"),
            r#"{"algorithm_type":"8404","port":0}"#,
        )
        .expect("config json");
        path
    }

    fn init_args(dir: &std::path::Path) -> (String, String, String, String, u16, Option<String>) {
        (
            dir.join("config/config.json")
                .to_string_lossy()
                .into_owned(),
            dir.join("config/device_pool.json")
                .to_string_lossy()
                .into_owned(),
            dir.join("config/filter.json")
                .to_string_lossy()
                .into_owned(),
            String::new(),
            0,
            None,
        )
    }

    /// Proves that the core at `base` really answers on its published port. The
    /// capability is part of the probe: `base_url()` alone is refused with 401,
    /// so a stale pair (released port or restarted core) must fail this.
    async fn health_ok(base: &str, capability: &str) -> bool {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(3))
            .build()
            .expect("client");
        match client
            .get(format!("{base}/_session/{capability}/health"))
            .send()
            .await
        {
            Ok(resp) => resp.status().as_u16() == 200,
            Err(_) => false,
        }
    }

    /// The review's reproducer: 8 concurrent initializations used to leave 1
    /// winner and 7 "address already in use" failures.
    #[tokio::test]
    async fn concurrent_initialization_all_observe_running() {
        let _guard = CORE_TEST_LOCK.lock().await;
        let _ = shutdown().await;
        let dir = runtime_dir("concurrent");

        let mut handles = Vec::new();
        for _ in 0..8 {
            let (cfg, pool, filter, runtime, port, mock) = init_args(&dir);
            handles.push(tokio::spawn(async move {
                init_core(cfg, pool, filter, runtime, port, mock).await
            }));
        }
        for handle in handles {
            let result = handle.await.expect("join").expect("init must succeed");
            assert_eq!(result, "running");
        }

        assert!(core_generation().await > 0);
        assert_eq!(status().await, "running");
        let base = base_url().await;
        let capability = session_capability().await;
        assert!(base.starts_with("http://127.0.0.1:"), "base url {base:?}");
        assert!(
            health_ok(&base, &capability).await,
            "the published core must serve /health"
        );

        shutdown().await.expect("shutdown");
        assert_eq!(core_generation().await, 0);
        assert_eq!(status().await, "starting");
        // The port is released *and* the capability is retired, so the stale
        // pair cannot answer even if another listener took the port.
        assert!(
            !health_ok(&base, &capability).await,
            "shutdown must release the port"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn restart_gets_a_new_generation_and_a_working_port() {
        let _guard = CORE_TEST_LOCK.lock().await;
        let _ = shutdown().await;
        let dir = runtime_dir("restart");

        let (cfg, pool, filter, runtime, port, mock) = init_args(&dir);
        init_core(cfg, pool, filter, runtime, port, mock)
            .await
            .expect("first init");
        let first_generation = core_generation().await;
        let first_base = base_url().await;
        let first_capability = session_capability().await;

        shutdown().await.expect("shutdown");
        assert_eq!(core_generation().await, 0);

        let (cfg, pool, filter, runtime, port, mock) = init_args(&dir);
        init_core(cfg, pool, filter, runtime, port, mock)
            .await
            .expect("second init");
        let second_generation = core_generation().await;
        assert!(
            second_generation > first_generation,
            "a restarted core must have a newer generation ({second_generation} vs {first_generation})"
        );
        assert!(health_ok(&base_url().await, &session_capability().await).await);

        // A stale cleanup for the previous core must not disturb the new one.
        assert!(!cancel("stale-request-from-previous-core".to_string()));
        assert_eq!(status().await, "running");
        assert!(health_ok(&base_url().await, &session_capability().await).await);

        // The previous launch's capability must be dead: the new core has its
        // own, so a stale URL cannot answer even if the port is reused.
        assert!(!health_ok(&first_base, &first_capability).await);
        shutdown().await.expect("shutdown");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn shutdown_and_init_serialise_without_leaking_a_listener() {
        let _guard = CORE_TEST_LOCK.lock().await;
        let _ = shutdown().await;
        let dir = runtime_dir("serialise");

        let (cfg, pool, filter, runtime, port, mock) = init_args(&dir);
        init_core(cfg, pool, filter, runtime, port, mock)
            .await
            .expect("init");

        let shutdown_future = shutdown();
        let (cfg, pool, filter, runtime, port, mock) = init_args(&dir);
        let init_future = init_core(cfg, pool, filter, runtime, port, mock);
        let (stopped, started) = tokio::join!(shutdown_future, init_future);
        stopped.expect("shutdown");
        started.expect("init");

        // Whichever order the lock granted, the result is a fully formed core
        // or a fully stopped one - never a half-bound listener.
        if core_generation().await > 0 {
            assert_eq!(status().await, "running");
            assert!(health_ok(&base_url().await, &session_capability().await).await);
        } else {
            assert_eq!(status().await, "starting");
            assert!(base_url().await.is_empty());
        }
        shutdown().await.expect("shutdown");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
