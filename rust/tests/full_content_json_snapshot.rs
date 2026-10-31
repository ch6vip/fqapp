//! Serialization contract for the `full` and `content` (batch) endpoints.
//!
//! Both used to clone the whole `data` map (and `item_infos`) out of the
//! parsed response only to write an identical map back. They now take the
//! values out in place; these snapshots pin the bytes returned to callers so
//! the clone-free rewrite cannot change the wire format.

mod common;

use std::sync::Arc;

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;
use serde_json::{json, Value};

/// The pool's only device; `decrypt_upstream` uses its 16-byte AES-128 key.
const DEVICE_KEY_HEX: &str = "00000000000000000000000000000000";

fn request(path: &str, query: &str) -> Request {
    Request {
        method: "GET".to_string(),
        path: path.to_string(),
        query: query.to_string(),
        body: Vec::new(),
        headers: Vec::new(),
    }
}

async fn body_string(server: &Arc<Server>, req: &Request) -> (u16, String) {
    let resp = dispatch(server, req).await;
    let status = resp.status;
    let body = resp.into_bytes().await.expect("body");
    (status, String::from_utf8_lossy(&body).into_owned())
}

/// A server whose upstream answers every request with `reply`.
async fn server_replying(dir: &TempDir, reply: Value) -> (Arc<Server>, MockUpstream) {
    let mock = MockUpstream::start(move |_| MockReply::json(reply.clone())).await;
    let server = build_server(dir, Some(mock.origin.clone()), &[], &[], &pool_json(1)).await;
    (server, mock)
}

fn serialized(value: &Value) -> String {
    serde_json::to_string(value).expect("serialize expected payload")
}

fn encrypt_content(plain: &str) -> String {
    use base64::Engine as _;
    let key = hex::decode(DEVICE_KEY_HEX).expect("device key");
    let iv = [0x22u8; 16];
    let padded = fqapi_core::crypto::pkcs7_pad(plain.as_bytes(), 16);
    let body = fqapi_core::crypto::aes_cbc_encrypt(&padded, &key, &iv);
    let mut raw = Vec::with_capacity(16 + body.len());
    raw.extend_from_slice(&iv);
    raw.extend_from_slice(&body);
    base64::engine::general_purpose::STANDARD.encode(raw)
}

#[tokio::test]
async fn full_keeps_the_item_infos_payload_byte_for_byte() {
    let upstream = json!({
        "code": 0,
        "msg": "ok",
        "data": {
            "book_id": "7000000000000000001",
            "item_infos": {
                "chapter-1": {"title": "First", "key": "", "content": ""},
                "chapter-2": {"title": "Second", "extra": {"nested": [1, 2, 3]}},
            }
        }
    });
    let dir = TempDir::new("full-snapshot");
    let (server, _mock) = server_replying(&dir, upstream.clone()).await;

    let (status, body) = body_string(
        &server,
        &request(
            "/api/v1/chapters/full",
            "book_id=7000000000000000001&item_ids=chapter-1,chapter-2",
        ),
    )
    .await;
    assert_eq!(status, 200, "body: {body}");
    assert_eq!(body, serialized(&upstream));
}

#[tokio::test]
async fn full_keeps_unprocessed_payloads_byte_for_byte() {
    let cases = [
        json!({"code": 0, "data": {}, "msg": "ok"}),
        json!({"code": 0, "data": {"book_id": "700"}, "msg": "ok"}),
        json!({"code": 0, "data": "not-an-object", "msg": "ok"}),
        json!({"code": 0, "data": {"item_infos": [{"title": "A"}, 42]}, "msg": "ok"}),
        json!({"code": 0, "msg": "no data at all"}),
    ];
    for upstream in cases {
        let dir = TempDir::new("full-passthrough");
        let (server, _mock) = server_replying(&dir, upstream.clone()).await;
        let (status, body) = body_string(
            &server,
            &request("/api/v1/chapters/full", "book_id=700&item_ids=chapter-1"),
        )
        .await;
        assert_eq!(status, 200, "upstream {upstream} body: {body}");
        assert_eq!(body, serialized(&upstream), "upstream {upstream}");
    }
}

#[tokio::test]
async fn content_batch_decrypts_in_place_without_changing_the_json_shape() {
    let cipher = encrypt_content("第一章正文");
    let upstream = json!({
        "code": 0,
        "msg": "ok",
        "data": {
            "10": {"title": "A", "content": cipher},
            "11": {"title": "B", "content": ""},
        }
    });
    let expected = json!({
        "code": 0,
        "msg": "ok",
        "data": {
            "10": {"title": "A", "content": "第一章正文"},
            "11": {"title": "B", "content": ""},
        }
    });
    let dir = TempDir::new("content-snapshot");
    let (server, _mock) = server_replying(&dir, upstream).await;

    let (status, body) = body_string(
        &server,
        &request("/api/v1/chapters/batch", "item_ids=10,11"),
    )
    .await;
    assert_eq!(status, 200, "body: {body}");
    assert_eq!(body, serialized(&expected));
}

#[tokio::test]
async fn content_batch_returns_pass_through_payloads_unchanged() {
    let cases = [
        json!({"code": 0, "data": {}, "msg": "ok"}),
        json!({"code": 0, "data": "not-an-object", "msg": "ok"}),
        json!({"code": 0, "msg": "no data at all"}),
    ];
    for upstream in cases {
        let dir = TempDir::new("content-passthrough");
        let (server, _mock) = server_replying(&dir, upstream.clone()).await;
        let (status, body) =
            body_string(&server, &request("/api/v1/chapters/batch", "item_ids=10")).await;
        assert_eq!(status, 200, "upstream {upstream} body: {body}");
        assert_eq!(body, serialized(&upstream), "upstream {upstream}");
    }
}
