//! Host-side contract tests against a scripted mock upstream.
//!
//! Covers the review's V1.1 (business errors, auth failures, gzip, exact ids,
//! device/session binding) and the Go-derived DH content fixture from V1.3.

mod common;

use common::{build_server, pool_json, query_map, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::dhcontent::set_dh_content_in_place;
use fqapi_core::endpoints::{router, session, Params, INTERNAL_DEVICE_PIN_KEY};
use fqapi_core::sign::Manager;
use fqapi_core::upstream::{UpstreamClient, UpstreamRequest};
use num_bigint::BigUint;
use serde_json::{json, Value};
use std::sync::Arc;

async fn server_with(dir: &TempDir, origin: &str) -> Arc<fqapi_core::endpoints::Server> {
    build_server(dir, Some(origin.to_string()), &[], &[], &pool_json(5)).await
}

fn api_get(path: &str, query: &str) -> Request {
    Request {
        method: "GET".to_string(),
        path: path.to_string(),
        query: query.to_string(),
        body: Vec::new(),
        headers: Vec::new(),
    }
}

async fn json_body(resp: fqapi_core::dispatch::Response) -> (u16, Value) {
    let status = resp.status;
    let bytes = resp.into_bytes().await.expect("body");
    let value = serde_json::from_slice(&bytes).unwrap_or_else(|e| {
        panic!(
            "response is not JSON ({e}): {}",
            String::from_utf8_lossy(&bytes)
        )
    });
    (status, value)
}

// --- V1.1: HTTP 200 carrying a business error must survive the Web bridge ----

#[tokio::test]
async fn web_bridge_preserves_an_upstream_business_error() {
    for code in [json!(101104), json!(0.5), json!(200.5)] {
        let expected = code.clone();
        let upstream = MockUpstream::start(move |_| {
            MockReply::json(json!({
                "code": code,
                "message": "BOOK_NOT_EXIST_ERROR",
                "data": null,
            }))
        })
        .await;
        let dir = TempDir::new("biz-error");
        let server = server_with(&dir, &upstream.origin).await;

        let (status, body) = json_body(
            dispatch(
                &server,
                &api_get("/api/search", "source=%E7%95%AA%E8%8C%84&query=x&page=1"),
            )
            .await,
        )
        .await;

        assert_eq!(status, 200, "business errors travel as HTTP 200");
        assert_eq!(
            body["code"], expected,
            "the upstream business code must not be rewritten"
        );
        assert_eq!(body["message"], "BOOK_NOT_EXIST_ERROR");
        assert!(
            body.get("data").is_some(),
            "the failure envelope must survive intact"
        );
        assert!(body.get("success").is_none());
        upstream.shutdown();
    }
}

#[tokio::test]
async fn web_bridge_still_wraps_a_successful_payload() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"item_data_list": []}}))
    })
    .await;
    let dir = TempDir::new("biz-ok");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/search", "source=%E7%95%AA%E8%8C%84&query=x"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["code"], 200);
    assert_eq!(body["message"], "success");
    assert_eq!(body["data"], json!({"item_data_list": []}));
    upstream.shutdown();
}

#[tokio::test]
async fn web_bridge_reports_a_transport_failure_as_500() {
    let upstream = MockUpstream::start(|_| MockReply::status(500)).await;
    let dir = TempDir::new("biz-500");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/directory", "source=%E7%95%AA%E8%8C%84&book_id=1"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 500);
    assert_eq!(body["code"], 500);
    upstream.shutdown();
}

// --- V1.1: auth statuses are classified as device failures ------------------

#[tokio::test]
async fn auth_statuses_are_device_failures_and_500_is_not() {
    for status in [401u16, 403, 500, 503] {
        let upstream = MockUpstream::start(move |_| MockReply::status(status)).await;
        let dir = TempDir::new("auth");
        let origin = upstream.origin.clone();
        let pool = fqapi_core::device::DevicePool::new(dir.join("pool.json"))
            .await
            .expect("pool");
        let client =
            UpstreamClient::with_mock_origin(pool, Manager::new(), origin.clone()).expect("client");

        let err = client
            .do_request(&UpstreamRequest {
                method: Some("GET".to_string()),
                url: format!("{origin}/probe"),
                ..Default::default()
            })
            .await
            .expect_err("non-200 must fail");

        let expected_device_failure = matches!(status, 401 | 403);
        assert_eq!(
            err.is_device_failed(),
            expected_device_failure,
            "HTTP {status} classification"
        );
        upstream.shutdown();
    }
}

// --- V1.1: gzip responses are inflated by the transport ---------------------

#[tokio::test]
async fn gzip_responses_are_inflated_with_and_without_the_header() {
    let payload = br#"{"code":0,"data":{"ok":true}}"#.to_vec();
    for with_header in [true, false] {
        let body_for_reply = payload.clone();
        let upstream = MockUpstream::start(move |_| {
            let gz = fqapi_core::crypto::gzip(&body_for_reply);
            let mut reply = MockReply {
                status: 200,
                headers: Vec::new(),
                body: gz,
            };
            if with_header {
                reply
                    .headers
                    .push(("content-encoding".to_string(), "gzip".to_string()));
            }
            reply
        })
        .await;
        let dir = TempDir::new("gzip");
        let origin = upstream.origin.clone();
        let pool = fqapi_core::device::DevicePool::new(dir.join("pool.json"))
            .await
            .expect("pool");
        let client =
            UpstreamClient::with_mock_origin(pool, Manager::new(), origin.clone()).expect("client");

        let (bytes, _) = client
            .do_request(&UpstreamRequest {
                method: Some("GET".to_string()),
                url: format!("{origin}/gzip"),
                ..Default::default()
            })
            .await
            .expect("inflated body");
        assert_eq!(
            bytes, payload,
            "gzip (header={with_header}) must be inflated"
        );
        upstream.shutdown();
    }
}

// --- V1.1: exact ids and parameters reach the upstream unchanged ------------

#[tokio::test]
async fn exact_media_ids_and_params_reach_the_upstream() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("exact-id");
    let server = server_with(&dir, &upstream.origin).await;

    let ids = "7507512821328904729,7507960973773242905";
    let (status, _) =
        json_body(dispatch(&server, &api_get(&format!("/api/v1/items/{ids}"), "")).await).await;
    assert_eq!(status, 200);

    let recorded = upstream.last_request().expect("one upstream call");
    assert_eq!(recorded.path, "/api/novel/book/directory/detail/v/");
    let query = query_map(&recorded.query);
    assert_eq!(query.get("aid").map(String::as_str), Some("1319"));
    assert_eq!(
        query.get("item_ids").map(String::as_str),
        Some(ids),
        "19-digit ids must not be truncated or re-encoded"
    );
    assert!(
        !query.contains_key("device_id"),
        "item_info is not device-bound"
    );
    upstream.shutdown();
}

// --- V1.1: a session is pinned to the device that opened it -----------------

#[tokio::test]
async fn a_recorded_session_pins_its_device_across_pages() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"session_id": "opened-by-upstream"}}))
    })
    .await;
    let dir = TempDir::new("pin");
    let server = server_with(&dir, &upstream.origin).await;

    let pinned = server
        .ctx
        .pool
        .get_by_id("0000000000000000")
        .await
        .expect("device 0");
    session::record_device_session("session-A", &pinned.device_id);

    // The router resolves the echoed session to the pinned device.
    let mut params = Params::from_pairs(vec![("session_id".to_string(), "session-A".to_string())]);
    let resolved = router::pin_from_session(&mut params, &server.ctx.pool).await;
    assert_eq!(resolved.as_deref(), Some("0000000000000000"));
    assert_eq!(
        params.get(INTERNAL_DEVICE_PIN_KEY),
        Some("0000000000000000")
    );

    // And the endpoint really sends that device to the upstream.
    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get(
                "/api/v1/recommend/homepage",
                "tab_type=2&session_id=session-A",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);

    let recorded = upstream.last_request().expect("one upstream call");
    let query = query_map(&recorded.query);
    assert_eq!(
        query.get("device_id").map(String::as_str),
        Some("0000000000000000"),
        "page N+1 must reuse the device that opened the session"
    );
    assert_eq!(
        query.get("iid").map(String::as_str),
        Some("9000000000000000000"),
        "the pinned device's install id is substituted too"
    );
    assert_eq!(
        query.get("session_id").map(String::as_str),
        Some("session-A")
    );
    upstream.shutdown();
}

// --- V1.3: Go-derived DH content fixture ------------------------------------

const DH_FIXTURE: &str = include_str!("../testdata/dh_content_fixture.json");

#[test]
fn dh_content_decrypts_a_go_generated_fixture() {
    let fixture: Value =
        serde_json::from_str(DH_FIXTURE).expect("dh_content_fixture.json is valid JSON");
    let f = &fixture["dh_content"];
    let plain = f["plain_html"].as_str().expect("plain_html");
    let key = f["key_b64"].as_str().expect("key_b64");
    let cipher = f["cipher_b64"].as_str().expect("cipher_b64");

    let state = fqapi_core::upstream::dh::DHState {
        a: BigUint::from(1u32),
    };

    let raw = serde_json::to_vec(&json!({
        "code": 0,
        "data": { "content": cipher, "item_id": "chapter" },
    }))
    .unwrap();
    let headers = vec![
        ("Y".to_string(), key.to_string()),
        // The current upstream signals "ciphertext is in the body" with c=1.
        ("C".to_string(), "1".to_string()),
    ];

    let result = set_dh_content_in_place(&raw, &headers, &state).expect("decrypt");
    let data = &result["data"];
    assert_eq!(data["content"], json!(plain));
    assert_eq!(data["content_decrypted"], json!(true));
    assert_eq!(
        data["item_id"], "chapter",
        "every other upstream field must survive the in-place rewrite"
    );
}

#[test]
fn dh_content_failure_modes_fail_closed() {
    let fixture: Value = serde_json::from_str(DH_FIXTURE).expect("fixture");
    let f = &fixture["dh_content"];
    let key = f["key_b64"].as_str().unwrap();
    let state = fqapi_core::upstream::dh::DHState {
        a: BigUint::from(1u32),
    };

    // Encrypted response without a usable key or ciphertext.
    for headers in [
        vec![
            ("Y".to_string(), key.to_string()),
            ("C".to_string(), "1".to_string()),
        ],
        vec![("C".to_string(), "1".to_string())],
    ] {
        let raw = br#"{"code":0,"data":{"content":"not base64!"}}"#.to_vec();
        assert!(
            set_dh_content_in_place(&raw, &headers, &state).is_err(),
            "ciphertext without a valid key must not be published"
        );
    }

    // Decrypted bytes that are not valid UTF-8 must not become a chapter.
    let raw = serde_json::to_vec(&json!({
        "data": { "content": f["invalid_utf8_cipher"].as_str().unwrap() },
    }))
    .unwrap();
    let headers = vec![
        (
            "Y".to_string(),
            f["invalid_utf8_key"].as_str().unwrap().to_string(),
        ),
        ("C".to_string(), "1".to_string()),
    ];
    assert!(
        set_dh_content_in_place(&raw, &headers, &state).is_err(),
        "invalid UTF-8 must not be reported as a readable chapter"
    );
}
