//! Upstream client retry contract.
//!
//! A transport error, a 429, or a 5xx says nothing about the pooled identity:
//! those are retried on the same device with a short backoff. Only a definite
//! auth rejection retires the device and rotates to a fresh one.

mod common;

use common::{pool_json, query_map, MockReply, MockUpstream, TempDir};
use fqapi_core::device::DevicePool;
use fqapi_core::sign::Manager;
use fqapi_core::upstream::{ClientError, UpstreamClient, UpstreamRequest};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// Same-device retries in `upstream/client.rs` (`TRANSIENT_RETRIES`).
const TRANSIENT_RETRIES: usize = 2;

async fn client_with_pool(dir: &TempDir, origin: &str) -> (Arc<DevicePool>, UpstreamClient) {
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::with_mock_origin(path, origin.to_string())
        .await
        .expect("pool");
    let client = UpstreamClient::with_mock_origin(pool.clone(), Manager::new(), origin.to_string())
        .expect("client");
    (pool, client)
}

/// A device-signed GET whose query records which pool entry answered it.
fn probe(origin: &str) -> UpstreamRequest {
    UpstreamRequest {
        method: Some("GET".to_string()),
        url: format!("{origin}/probe?device_id={{device_id}}"),
        ..Default::default()
    }
}

fn device_ids(requests: &[common::Recorded]) -> Vec<String> {
    requests
        .iter()
        .map(|r| {
            query_map(&r.query)
                .get("device_id")
                .cloned()
                .unwrap_or_default()
        })
        .collect()
}

#[tokio::test]
async fn a_5xx_is_retried_on_the_same_device_until_it_succeeds() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |_| {
        if counter.fetch_add(1, Ordering::SeqCst) < TRANSIENT_RETRIES {
            MockReply::status(503)
        } else {
            MockReply::json(json!({ "code": 0, "data": {} }))
        }
    })
    .await;
    let dir = TempDir::new("retry-5xx");
    let (pool, client) = client_with_pool(&dir, &upstream.origin).await;

    let (body, device) = client
        .do_with_device_capped(&probe(&upstream.origin), 1024)
        .await
        .expect("the retried attempt must answer");
    let payload: Value = serde_json::from_slice(&body).expect("json body");
    assert_eq!(payload["code"], json!(0));

    let requests = upstream.requests();
    assert_eq!(
        requests.len(),
        TRANSIENT_RETRIES + 1,
        "a 5xx must be retried, not surfaced"
    );
    let ids = device_ids(&requests);
    assert!(
        ids.iter().all(|id| id == &device.device_id),
        "a transient failure must stay on the same device: {ids:?} vs {}",
        device.device_id
    );
    assert_eq!(pool.count().await, 5, "a retry must not retire the device");
    upstream.shutdown();
}

#[tokio::test]
async fn an_exhausted_5xx_is_transient_not_a_device_failure() {
    let upstream = MockUpstream::start(|_| MockReply::status(503)).await;
    let dir = TempDir::new("retry-5xx-exhausted");
    let (pool, client) = client_with_pool(&dir, &upstream.origin).await;

    let err = client
        .do_with_device_capped(&probe(&upstream.origin), 1024)
        .await
        .expect_err("a persistent 5xx must surface");
    assert!(
        matches!(err, ClientError::Transient { .. }),
        "a server fault must not be classified as a device failure: {err:?}"
    );
    assert!(!err.is_device_failed());

    let requests = upstream.requests();
    assert_eq!(requests.len(), TRANSIENT_RETRIES + 1);
    assert!(
        requests.iter().all(|r| r.path == "/probe"),
        "no device replacement may run for a 5xx: {:?}",
        requests.iter().map(|r| r.path.as_str()).collect::<Vec<_>>()
    );
    assert_eq!(pool.count().await, 5);
    upstream.shutdown();
}

#[tokio::test]
async fn a_429_is_retried_and_honours_retry_after() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |_| {
        if counter.fetch_add(1, Ordering::SeqCst) == 0 {
            MockReply {
                status: 429,
                headers: vec![("retry-after".to_string(), "0".to_string())],
                body: Vec::new(),
            }
        } else {
            MockReply::json(json!({ "code": 0 }))
        }
    })
    .await;
    let dir = TempDir::new("retry-429");
    let (pool, client) = client_with_pool(&dir, &upstream.origin).await;

    client
        .do_with_device_capped(&probe(&upstream.origin), 1024)
        .await
        .expect("the retried attempt must answer");
    assert_eq!(upstream.requests().len(), 2);
    assert_eq!(pool.count().await, 5);
    upstream.shutdown();
}

/// Accepts TCP connections and closes them without a response, which surfaces
/// to the client as a transport error.
async fn closing_listener() -> (String, Arc<AtomicUsize>) {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let connects = Arc::new(AtomicUsize::new(0));
    let counter = connects.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            counter.fetch_add(1, Ordering::SeqCst);
            drop(stream);
        }
    });
    (format!("http://{addr}"), connects)
}

#[tokio::test]
async fn a_transport_error_is_retried_on_the_same_device_without_retiring_it() {
    let (origin, connects) = closing_listener().await;
    let dir = TempDir::new("retry-transport");
    let (pool, client) = client_with_pool(&dir, &origin).await;

    let err = client
        .do_with_device_capped(&probe(&origin), 1024)
        .await
        .expect_err("a closed connection must fail");
    assert!(
        matches!(err, ClientError::Transient { .. }),
        "a network hiccup must not be classified as a device failure: {err:?}"
    );
    assert!(!err.is_device_failed());
    assert_eq!(
        connects.load(Ordering::SeqCst),
        TRANSIENT_RETRIES + 1,
        "the same device must be tried again before giving up"
    );
    assert_eq!(
        pool.count().await,
        5,
        "a transport error must not retire the device"
    );
}

#[tokio::test]
async fn an_auth_rejection_is_a_device_failure_and_is_not_same_device_retried() {
    let upstream = MockUpstream::start(|_| MockReply::status(401)).await;
    let dir = TempDir::new("auth-single-shot");
    let (pool, client) = client_with_pool(&dir, &upstream.origin).await;

    let err = client
        .do_request_capped(&probe(&upstream.origin), 1024)
        .await
        .expect_err("401 must fail");
    assert!(
        err.is_device_failed(),
        "a definite auth rejection still retires the identity: {err:?}"
    );
    assert_eq!(
        upstream.requests().len(),
        1,
        "an auth rejection is a device fault, not a transient retry"
    );
    assert_eq!(pool.count().await, 5);
    upstream.shutdown();
}
