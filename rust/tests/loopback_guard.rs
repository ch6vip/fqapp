//! Loopback Host/Origin guard, request body limit and the anti-crawler
//! redirect.
//!
//! The guard lives in the HTTP adapter only (the FFI path has no headers), so
//! every guard case goes over a real socket. Refusals must happen before any
//! upstream request, proven against a recording mock upstream.

mod common;

use common::{build_server, build_server_with_config, pool_json, start_loopback};
use common::{MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const COMMENT_ADD: &str = "/api/v1/series/123/comments/add?text=x";

async fn comment_server(
    name: &str,
) -> (
    TempDir,
    MockUpstream,
    std::sync::Arc<fqapi_core::endpoints::Server>,
) {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"comment_info": {"comment_id": "c9"}}}))
    })
    .await;
    let dir = TempDir::new(name);
    let server = build_server(&dir, Some(upstream.origin.clone()), &[], &[], &pool_json(5)).await;
    (dir, upstream, server)
}

/// Sends raw request bytes and returns the status code and full response.
/// reqwest always derives `Host` from the URL, so forged or missing `Host`
/// values need a hand-written request.
async fn raw(port: u16, request: &str) -> (u16, String) {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("connect");
    stream
        .write_all(request.as_bytes())
        .await
        .expect("write request");
    let mut out = Vec::new();
    stream.read_to_end(&mut out).await.expect("read response");
    let text = String::from_utf8_lossy(&out).into_owned();
    let status = text
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    (status, text)
}

#[tokio::test]
async fn own_hosts_are_served() {
    let dir = TempDir::new("guard-own-host");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let (port, task) = start_loopback(server).await;

    for host in [
        format!("127.0.0.1:{port}"),
        format!("localhost:{port}"),
        format!("LocalHost:{port}"),
    ] {
        let (status, text) = raw(
            port,
            &format!("GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert_eq!(status, 200, "host {host}");
        assert!(text.contains("\"devices\":3"), "host {host}: {text}");
    }

    // Same-origin browser request (Web UI) and a real client both pass.
    let client = reqwest::Client::new();
    let response = client
        .get(format!("http://127.0.0.1:{port}/health"))
        .header("origin", format!("http://127.0.0.1:{port}"))
        .send()
        .await
        .expect("same-origin request");
    assert_eq!(response.status().as_u16(), 200);
    task.abort();
}

#[tokio::test]
async fn foreign_or_missing_hosts_are_refused_without_a_body() {
    let dir = TempDir::new("guard-foreign-host");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let (port, task) = start_loopback(server).await;

    let other_port = port.wrapping_add(1);
    for host in [
        // DNS rebinding: a foreign name resolved to 127.0.0.1.
        format!("evil.example:{port}"),
        "evil.example".to_string(),
        // Right host, wrong port, and portless forms.
        format!("127.0.0.1:{other_port}"),
        "127.0.0.1".to_string(),
        "localhost".to_string(),
        // Look-alikes that a prefix/suffix match would accept.
        format!("127.0.0.1.evil.example:{port}"),
        format!("localhost.evil.example:{port}"),
    ] {
        let (status, text) = raw(
            port,
            &format!("GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert_eq!(status, 403, "host {host}: {text}");
        assert!(text.contains("host not allowed"), "host {host}: {text}");
        assert!(!text.contains("devices"), "host {host} leaked: {text}");
    }

    // HTTP/1.0 lets a client omit Host entirely.
    let (status, text) = raw(port, "GET /health HTTP/1.0\r\n\r\n").await;
    assert_eq!(status, 403, "{text}");
    assert!(!text.contains("devices"), "{text}");
    task.abort();
}

#[tokio::test]
async fn cross_origin_writes_never_reach_upstream() {
    let (_dir, upstream, server) = comment_server("guard-foreign-origin").await;
    let (port, task) = start_loopback(server).await;
    let client = reqwest::Client::new();

    for origin in [
        "https://evil.example".to_string(),
        "null".to_string(),
        format!("http://evil.example:{port}"),
        // Scheme and port are part of the origin.
        format!("https://127.0.0.1:{port}"),
        format!("http://127.0.0.1:{}", port.wrapping_add(1)),
    ] {
        // The shape of a cross-site HTML form POST: no preflight is sent.
        let response = client
            .post(format!("http://127.0.0.1:{port}{COMMENT_ADD}"))
            .header("origin", &origin)
            .header("content-type", "application/x-www-form-urlencoded")
            .body("")
            .send()
            .await
            .expect("cross-origin POST");
        assert_eq!(response.status().as_u16(), 403, "origin {origin}");
        let body: serde_json::Value = response.json().await.expect("json refusal");
        assert_eq!(body["error"], "origin not allowed", "origin {origin}");
    }
    assert!(upstream.requests().is_empty());

    // Positive control: the same write from this listener's own origin, and
    // from a native client that sends no Origin, both go through.
    for origin in [Some(format!("http://localhost:{port}")), None] {
        let mut builder = client.post(format!("http://127.0.0.1:{port}{COMMENT_ADD}"));
        if let Some(origin) = &origin {
            builder = builder.header("origin", origin);
        }
        let response = builder.send().await.expect("own-origin POST");
        assert_eq!(response.status().as_u16(), 200, "origin {origin:?}");
    }
    assert_eq!(upstream.requests().len(), 2);
    task.abort();
    upstream.shutdown();
}

#[tokio::test]
async fn oversized_bodies_are_refused_and_moderate_ones_accepted() {
    let (_dir, upstream, server) = comment_server("guard-body-limit").await;
    let (port, task) = start_loopback(server).await;

    // Announced oversize: refused from the header, before any body is read.
    let limit = fqapi_core::server::MAX_REQUEST_BODY;
    let (status, text) = raw(
        port,
        &format!(
            "POST {COMMENT_ADD} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n",
            limit + 1
        ),
    )
    .await;
    assert_eq!(status, 413, "{text}");
    assert!(upstream.requests().is_empty());

    // Above axum's 2 MiB default but inside our limit: must be accepted, which
    // proves the DefaultBodyLimit layer reaches the fallback handler.
    let client = reqwest::Client::new();
    let response = client
        .post(format!("http://127.0.0.1:{port}{COMMENT_ADD}"))
        .body(vec![b' '; 3 * 1024 * 1024])
        .send()
        .await
        .expect("3 MiB POST");
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(upstream.requests().len(), 1);
    task.abort();
    upstream.shutdown();
}

#[tokio::test]
async fn anti_crawler_redirect_carries_a_location_header() {
    let dir = TempDir::new("anti-crawler");
    let server = build_server_with_config(
        &dir,
        None,
        &[],
        &[],
        &pool_json(1),
        r#"{"algorithm_type":"8404","port":0,
            "anti_crawler":{"enabled":true,"redirect_url":"https://www.example.com/"}}"#,
    )
    .await;
    let request = Request {
        method: "GET".to_string(),
        path: "/no/such/route".to_string(),
        ..Request::default()
    };
    let response = dispatch(&server, &request).await;
    assert_eq!(response.status, 302);
    assert!(response
        .headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("location") && v == "https://www.example.com/"));

    // Over the socket the client sees a real redirect, not a body.
    let (port, task) = start_loopback(server).await;
    let (status, text) = raw(
        port,
        &format!(
            "GET /no/such/route HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
        ),
    )
    .await;
    assert_eq!(status, 302, "{text}");
    assert!(
        text.to_ascii_lowercase()
            .contains("location: https://www.example.com/"),
        "{text}"
    );
    task.abort();
}
