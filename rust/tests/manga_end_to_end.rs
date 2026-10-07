//! End-to-end manga chain: business request -> signed upstream -> AES-128-CBC
//! content decrypt -> per-image download -> AES-256-GCM image decrypt -> file
//! written under the runtime src dir -> served URL/HTML -> real loopback fetch.
//!
//! The chapter body and the encrypted images are produced here with the same
//! upstream wire shapes
//! (base64(iv[16] ‖ AES-128-CBC(pkcs7(json))); image: iv[12] ‖ ct ‖ tag[16]).
//! Nothing touches the network, a device or the real device pool.

mod common;

use std::sync::Arc;

use common::{build_server, pool_json, start_loopback, Loopback, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use fqapi_core::endpoints::Server;

/// Go-generated payloads and expectations (cmd/mangafix in the pinned oracle):
/// the small PNG, the 4 KiB one the endpoint's 100-byte gate accepts, and the
/// AES-256-GCM key they were sealed with.
const FIXTURE: &str = include_str!("../testdata/manga_image_fixture.json");

fn fixture() -> serde_json::Value {
    serde_json::from_str(FIXTURE).expect("manga_image_fixture.json")
}

fn fixture_bytes(f: &serde_json::Value, key: &str) -> Vec<u8> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD
        .decode(f[key].as_str().expect(key))
        .expect("base64 fixture")
}

fn encrypt_upstream(plain: &[u8], secret_key_hex: &str) -> String {
    use base64::Engine as _;
    let key = hex::decode(secret_key_hex).expect("key hex");
    let iv = [0x11u8; 16];
    let body =
        fqapi_core::crypto::aes_cbc_encrypt(&fqapi_core::crypto::pkcs7_pad(plain, 16), &key, &iv);
    let mut raw = Vec::with_capacity(16 + body.len());
    raw.extend_from_slice(&iv);
    raw.extend_from_slice(&body);
    base64::engine::general_purpose::STANDARD.encode(raw)
}

fn request(path: &str, query: &str) -> Request {
    Request {
        method: "GET".to_string(),
        path: path.to_string(),
        query: query.to_string(),
        body: Vec::new(),
        headers: Vec::new(),
    }
}

/// Fetches a path from the real loopback adapter, carrying its capability.
async fn http_get(lb: &Loopback, path: &str) -> (u16, Vec<(String, String)>, Vec<u8>) {
    let client = reqwest::Client::builder().build().expect("client");
    let resp = client
        .get(lb.url(path))
        .send()
        .await
        .expect("loopback request");
    let status = resp.status().as_u16();
    let headers: Vec<(String, String)> = resp
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).into_owned(),
            )
        })
        .collect();
    let body = resp.bytes().await.expect("body").to_vec();
    (status, headers, body)
}

async fn body_string(server: &Arc<Server>, req: &Request) -> (u16, String) {
    let resp = dispatch(server, req).await;
    let status = resp.status;
    let body = resp.into_bytes().await.expect("body");
    (status, String::from_utf8_lossy(&body).into_owned())
}

/// Builds the mock that answers the chapter body and one encrypted image.
async fn manga_fixture() -> (TempDir, Arc<Server>, MockUpstream, Vec<u8>, String) {
    let dir = TempDir::new("manga-e2e");
    let mock = MockUpstream::start(|req| {
        if req.path.contains("/origin/") {
            return MockReply {
                status: 200,
                headers: vec![("content-type".to_string(), "image/png".to_string())],
                body: IMAGE.with(|i| i.borrow().clone()),
            };
        }
        MockReply::json(serde_json::json!({
            "data": { "book_id": "7000000000000000001", "content": CONTENT.with(|c| c.borrow().clone()) }
        }))
    })
    .await;

    // Go-generated: the 4 KiB payload clears the endpoint's >100-byte gate.
    let fixture = fixture();
    let f = &fixture["manga_image"];
    let image_key_hex = f["key_hex"].as_str().expect("key_hex").to_string();
    let plain =
        hex::decode(f["large_plain_hex"].as_str().expect("large_plain_hex")).expect("hex payload");
    let wire = fixture_bytes(f, "large_wire_b64");

    let chapter = serde_json::json!({
        "encrypt_key": image_key_hex,
        "picInfos": [ { "picUrl": fixture["manga_image"]["url_png"].as_str().unwrap() } ]
    })
    .to_string();
    // pool_json's least-recently-used device is index 0, whose secret_key is
    // 32 hex zeros (AES-128).
    let content = encrypt_upstream(chapter.as_bytes(), "00000000000000000000000000000000");

    IMAGE.with(|i| *i.borrow_mut() = wire);
    CONTENT.with(|c| *c.borrow_mut() = content);

    let server = build_server(&dir, Some(mock.origin.clone()), &[], &[], &pool_json(5)).await;
    (dir, server, mock, plain, image_key_hex)
}

thread_local! {
    /// The encrypted body the mock upstream returns for the image URL.
    static IMAGE: std::cell::RefCell<Vec<u8>> = const { std::cell::RefCell::new(Vec::new()) };
    /// The AES-128-CBC encrypted chapter body.
    static CONTENT: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
}

#[tokio::test]
async fn manga_chapter_is_downloaded_decrypted_written_and_served() {
    let (_dir, server, mock, plain, _key) = manga_fixture().await;

    let (status, body) =
        body_string(&server, &request("/api/v1/manga/7507512821328904729", "")).await;
    assert_eq!(status, 200, "body: {body}");
    let parsed: serde_json::Value = serde_json::from_str(&body).expect("json envelope");
    let images = parsed["images"].as_array().expect("images array");
    let seen: Vec<String> = mock.requests().iter().map(|r| r.path.clone()).collect();
    assert_eq!(
        images.len(),
        1,
        "one picture must be decrypted: {body} | upstream requests: {seen:?}"
    );
    let served = images[0].as_str().expect("served url");
    assert!(served.starts_with("/src/"), "served url: {served}");

    // The business request went out signed to the mock, and the image was
    // fetched from the URL carried inside the decrypted chapter body.
    let paths: Vec<String> = mock.requests().iter().map(|r| r.path.clone()).collect();
    assert!(
        paths.iter().any(|p| p.contains("/reading/reader/")),
        "chapter request: {paths:?}"
    );
    assert!(
        paths.iter().any(|p| p.contains("/origin/1.png")),
        "image request: {paths:?}"
    );

    // The file on disk is the decrypted plaintext, byte for byte.
    let written = std::fs::read(
        std::path::Path::new(&server.ctx.src_dir).join(served.trim_start_matches("/src/")),
    )
    .expect("written image");
    assert_eq!(
        written, plain,
        "the stored image must be the decrypted payload"
    );

    // The served URL really answers over the loopback adapter.
    let lb = start_loopback(server).await;
    let (s, _headers, fetched) = http_get(&lb, served).await;
    assert_eq!(s, 200);
    assert_eq!(
        fetched, plain,
        "the served image must match the decrypted payload"
    );
    lb.task.abort();
}

#[tokio::test]
async fn show_html_returns_img_tags_pointing_at_the_served_files() {
    let (_dir, server, _mock, plain, _key) = manga_fixture().await;

    let (status, body) = body_string(&server, &request("/api/v1/manga/1", "show_html=1")).await;
    assert_eq!(status, 200, "body: {body}");
    let html = serde_json::from_str::<serde_json::Value>(&body).expect("json")["content"]
        .as_str()
        .expect("content html")
        .to_string();
    assert!(html.contains("<img src=\"/src/"), "html: {html}");
    let name = html
        .split("<img src=\"")
        .nth(1)
        .and_then(|s| s.split('"').next())
        .expect("src");
    let written = std::fs::read(
        std::path::Path::new(&server.ctx.src_dir).join(name.trim_start_matches("/src/")),
    )
    .expect("written image");
    assert_eq!(written, plain);
}

#[tokio::test]
async fn a_tampered_image_is_skipped_instead_of_being_published() {
    let (_dir, server, _mock, _plain, _key) = manga_fixture().await;
    // Corrupt the tag of the downloaded image.
    IMAGE.with(|i| {
        let mut v = i.borrow_mut();
        let last = v.len() - 1;
        v[last] ^= 0xff;
    });

    let (status, body) = body_string(&server, &request("/api/v1/manga/1", "")).await;
    assert_eq!(status, 200);
    let parsed: serde_json::Value = serde_json::from_str(&body).expect("json");
    assert_eq!(
        parsed["images"].as_array().map(|a| a.len()),
        Some(0),
        "a payload that fails authentication must not be served: {body}"
    );
}
