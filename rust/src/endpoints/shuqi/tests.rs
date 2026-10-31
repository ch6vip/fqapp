//! 正文预算与并发探测的单测。

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::Router;

use crate::config::Config;
use crate::device::DevicePool;
use crate::endpoints::Ctx;
use crate::error::ApiError;
use crate::filter::FilterManager;
use crate::sign::Manager;
use crate::upstream::UpstreamClient;

use super::content::{chapter_payload, first_ok};

/// 以本地 mock 上游构造最小 `Ctx`；`delay_for` 按请求 path 决定响应延迟。
/// 返回被访问过的 path 列表，用来断言某条腿有没有被发起。
async fn mock_ctx(delay_for: fn(&str) -> Duration) -> (Arc<Ctx>, Arc<Mutex<Vec<String>>>) {
    let seen: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let recorded = seen.clone();
    let app = Router::new().fallback(move |req: axum::extract::Request| {
        let recorded = recorded.clone();
        async move {
            let path = req.uri().path().to_string();
            recorded.lock().unwrap().push(path.clone());
            tokio::time::sleep(delay_for(&path)).await;
            (axum::http::StatusCode::NOT_FOUND, "")
        }
    });
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind mock");
    let port = listener.local_addr().expect("mock addr").port();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let origin = format!("http://127.0.0.1:{port}");

    let dir = std::env::temp_dir().join(format!(
        "fqapi-shuqi-budget-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let pool = DevicePool::with_mock_origin(dir.join("device_pool.json"), origin.clone())
        .await
        .expect("device pool");
    let up = UpstreamClient::with_mock_origin(pool.clone(), Manager::new(), origin)
        .expect("upstream client");
    let ctx = Ctx {
        up: Arc::new(up),
        pool,
        cfg: Arc::new(Config::default()),
        src_dir: dir.to_string_lossy().into_owned(),
        filters: Arc::new(FilterManager::default()),
    };
    (Arc::new(ctx), seen)
}

/// 总预算用尽后跳过 chapterinfo，并在错误里保留已收集的 CDN 原因。
#[tokio::test]
async fn chapter_budget_skips_chapterinfo_once_exhausted() {
    // 每个 CDN 探测都比预算慢：第一轮就被取消，后面的步骤不该再发起。
    let (ctx, seen) = mock_ctx(|_| Duration::from_secs(1)).await;
    let started = Instant::now();
    let err = chapter_payload(&ctx, "34078", "2180322", Duration::from_millis(300))
        .await
        .expect_err("the budget must run out");
    assert!(err.message().contains("budget"), "{}", err.message());
    assert!(err.message().contains("cdn attempts"), "{}", err.message());
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "the budget must bound the whole fetch, took {:?}",
        started.elapsed()
    );
    let paths = seen.lock().unwrap().clone();
    assert!(!paths.is_empty(), "the cdn was never probed");
    assert!(
        paths.iter().all(|p| !p.ends_with("/reader/chapterinfo")),
        "chapterinfo must be skipped after the budget: {paths:?}"
    );
}

/// CDN 都失败后，chapterinfo 也受剩余预算约束，错误里带上 CDN 原因。
#[tokio::test]
async fn chapterinfo_is_cut_off_by_the_remaining_budget() {
    let (ctx, seen) = mock_ctx(|path| {
        if path.ends_with("/reader/chapterinfo") {
            Duration::from_secs(5)
        } else {
            Duration::ZERO
        }
    })
    .await;
    let started = Instant::now();
    let err = chapter_payload(&ctx, "34078", "2180322", Duration::from_millis(800))
        .await
        .expect_err("chapterinfo must be cut off");
    let message = err.message();
    assert!(message.contains("chapterinfo exceeded"), "{message}");
    assert!(message.contains("budget"), "{message}");
    assert!(message.contains("cdn attempts"), "{message}");
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "chapterinfo must not outlive the budget, took {:?}",
        started.elapsed()
    );
    let paths = seen.lock().unwrap().clone();
    assert_eq!(
        paths
            .iter()
            .filter(|p| p.ends_with("/reader/chapterinfo"))
            .count(),
        1,
        "chapterinfo is attempted once: {paths:?}"
    );
}

/// 一个卡住的尝试不能拖住整轮：首个成功应立即返回。
#[tokio::test]
async fn first_ok_returns_without_waiting_for_a_stalled_attempt() {
    let mut attempts = Vec::new();
    for (label, delay_ms, ok) in [("stalled", 60_000u64, false), ("fast", 50u64, true)] {
        let fut = async move {
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;
            if ok {
                Ok("body")
            } else {
                Err(ApiError::Internal("stalled attempt".into()))
            }
        };
        attempts.push((label.to_string(), fut));
    }
    let started = std::time::Instant::now();
    let value = first_ok(attempts, Duration::from_secs(3))
        .await
        .expect("one success is enough");
    assert_eq!(value, "body");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "a stalled attempt must not hold the round open"
    );
}

/// 每次尝试各自限时，不能被传输层的 15s 默认超时拖住。
#[tokio::test]
async fn first_ok_bounds_each_attempt() {
    let attempt = async {
        tokio::time::sleep(Duration::from_secs(30)).await;
        Ok("late")
    };
    let started = std::time::Instant::now();
    let errors = first_ok(vec![("c1".to_string(), attempt)], Duration::from_millis(50))
        .await
        .expect_err("must time out");
    assert_eq!(errors.len(), 1);
    assert!(errors[0].contains("c1"), "{errors:?}");
    assert!(errors[0].contains("timed out"), "{errors:?}");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "the attempt timeout must bound the whole call"
    );
}

/// 全部失败时每条错误都要留下来，最终错误信息才能带上 CDN 侧的原因。
#[tokio::test]
async fn first_ok_keeps_every_error_when_all_attempts_fail() {
    let mut attempts = Vec::new();
    for (label, message) in [("c1", "first failure"), ("c2", "second failure")] {
        let fut = async move { Err::<&'static str, _>(ApiError::Internal(message.to_string())) };
        attempts.push((label.to_string(), fut));
    }
    let errors = first_ok(attempts, Duration::from_secs(1))
        .await
        .expect_err("all attempts fail");
    assert_eq!(errors.len(), 2);
    let joined = errors.join("; ");
    assert!(joined.contains("first failure"), "{joined}");
    assert!(joined.contains("second failure"), "{joined}");
}
