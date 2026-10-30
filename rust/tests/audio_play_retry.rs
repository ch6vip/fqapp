//! `audio_play` retries transient upstream failures.
//!
//! The attempt loop's comment promised jitter retries, but every transport or
//! JSON error returned through `?` before the next attempt. These tests pin
//! the retry contract: transient failures are retried up to the attempt budget
//! and the last failure is surfaced when the budget is exhausted.

mod common;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

fn audio_play_request() -> Request {
    Request {
        method: "GET".to_string(),
        path: "/api/v1/audio/play".to_string(),
        query: "item_ids=7579131531361258521&book_id=7491705400958405694".to_string(),
        body: Vec::new(),
        headers: Vec::new(),
    }
}

/// `AUDIO_PLAY_ATTEMPTS` in endpoints/audio.rs.
const AUDIO_PLAY_ATTEMPTS: usize = 4;

#[tokio::test]
async fn audio_play_retries_transient_500s_until_the_upstream_answers() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |_| {
        if counter.fetch_add(1, Ordering::SeqCst) < 2 {
            MockReply::status(500)
        } else {
            MockReply::json(serde_json::json!({ "code": 0, "data": {} }))
        }
    })
    .await;
    let dir = TempDir::new("audio-retry-500");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let resp = dispatch(&server, &audio_play_request()).await;
    assert_eq!(
        resp.status, 200,
        "the third attempt must answer the request"
    );
    assert_eq!(
        upstream.requests().len(),
        3,
        "two transient 500s must be retried, not surfaced"
    );
    upstream.shutdown();
}

#[tokio::test]
async fn audio_play_retries_a_truncated_json_body() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let upstream = MockUpstream::start(move |_| {
        if counter.fetch_add(1, Ordering::SeqCst) == 0 {
            // A 200 with a body that cannot be parsed is upstream jitter too.
            MockReply {
                status: 200,
                headers: vec![("content-type".to_string(), "application/json".to_string())],
                body: b"{\"code\":0,\"data\":".to_vec(),
            }
        } else {
            MockReply::json(serde_json::json!({ "code": 0, "data": {} }))
        }
    })
    .await;
    let dir = TempDir::new("audio-retry-json");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let resp = dispatch(&server, &audio_play_request()).await;
    assert_eq!(
        resp.status, 200,
        "the retry must get past the truncated body"
    );
    assert_eq!(upstream.requests().len(), 2);
    upstream.shutdown();
}

#[tokio::test]
async fn audio_play_returns_the_last_error_after_every_attempt_fails() {
    let upstream = MockUpstream::start(|_| MockReply::status(500)).await;
    let dir = TempDir::new("audio-retry-exhausted");
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;

    let resp = dispatch(&server, &audio_play_request()).await;
    assert_eq!(resp.status, 500, "a persistent failure must surface");
    assert_eq!(
        upstream.requests().len(),
        AUDIO_PLAY_ATTEMPTS,
        "every attempt in the budget must run before returning the last error"
    );
    upstream.shutdown();
}
