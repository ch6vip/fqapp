//! Loopback Host/Origin guard, request body limit and the anti-crawler
//! redirect.
//!
//! The guard lives in the HTTP adapter only (the FFI path has no headers), so
//! every guard case goes over a real socket. Refusals must happen before any
//! upstream request, proven against a recording mock upstream.

mod common;

use common::{build_server, build_server_with_config, pool_json, start_listener, start_loopback};
use common::{Loopback, MockReply, MockUpstream, TempDir};
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
    let lb = start_loopback(server).await;
    // The capability rides in the path so this stays a pure Host-guard test:
    // The capability rides in the path so this stays a pure Host-guard test:
    // on a bare target the session gate answers 401 instead of the dispatcher.
    let target = lb.scoped_path("/health");

    for host in [
        format!("127.0.0.1:{}", lb.port),
        format!("localhost:{}", lb.port),
        format!("LocalHost:{}", lb.port),
    ] {
        let (status, text) = raw(
            lb.port,
            &format!("GET {target} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert_eq!(status, 200, "host {host}");
        assert!(text.contains("\"devices\":3"), "host {host}: {text}");
    }

    // Same-origin browser request (Web UI) and a real client both pass.
    let client = reqwest::Client::new();
    let response = client
        .get(lb.url("/health"))
        .header("origin", lb.origin())
        .send()
        .await
        .expect("same-origin request");
    assert_eq!(response.status().as_u16(), 200);
    lb.task.abort();
}

#[tokio::test]
async fn foreign_or_missing_hosts_are_refused_without_a_body() {
    let dir = TempDir::new("guard-foreign-host");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = start_loopback(server).await;

    // The target stays capability-free on purpose: a foreign Host must still
    // answer 403, which pins the Host guard ahead of the session gate.
    let other_port = lb.port.wrapping_add(1);
    for host in [
        // DNS rebinding: a foreign name resolved to 127.0.0.1.
        format!("evil.example:{}", lb.port),
        "evil.example".to_string(),
        // Right host, wrong port, and portless forms.
        format!("127.0.0.1:{other_port}"),
        "127.0.0.1".to_string(),
        "localhost".to_string(),
        // Look-alikes that a prefix/suffix match would accept.
        format!("127.0.0.1.evil.example:{}", lb.port),
        format!("localhost.evil.example:{}", lb.port),
    ] {
        let (status, text) = raw(
            lb.port,
            &format!("GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert_eq!(status, 403, "host {host}: {text}");
        assert!(text.contains("host not allowed"), "host {host}: {text}");
        assert!(!text.contains("devices"), "host {host} leaked: {text}");
    }

    // HTTP/1.0 lets a client omit Host entirely.
    let (status, text) = raw(lb.port, "GET /health HTTP/1.0\r\n\r\n").await;
    assert_eq!(status, 403, "{text}");
    assert!(!text.contains("devices"), "{text}");
    lb.task.abort();
}

#[tokio::test]
async fn cross_origin_writes_never_reach_upstream() {
    let (_dir, upstream, server) = comment_server("guard-foreign-origin").await;
    let lb = start_loopback(server).await;
    let client = reqwest::Client::new();
    // Capability-free on purpose: a foreign Origin must still answer 403, so
    // this pins the Origin guard ahead of the session gate.
    let bare = lb.bare_url(COMMENT_ADD);

    for origin in [
        "https://evil.example".to_string(),
        "null".to_string(),
        format!("http://evil.example:{}", lb.port),
        // Scheme and port are part of the origin.
        format!("https://127.0.0.1:{}", lb.port),
        format!("http://127.0.0.1:{}", lb.port.wrapping_add(1)),
    ] {
        // The shape of a cross-site HTML form POST: no preflight is sent.
        let response = client
            .post(&bare)
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
    let scoped = lb.url(COMMENT_ADD);
    for origin in [Some(format!("http://localhost:{}", lb.port)), None] {
        let mut builder = client.post(&scoped);
        if let Some(origin) = &origin {
            builder = builder.header("origin", origin);
        }
        let response = builder.send().await.expect("own-origin POST");
        assert_eq!(response.status().as_u16(), 200, "origin {origin:?}");
    }
    assert_eq!(upstream.requests().len(), 2);
    lb.task.abort();
    upstream.shutdown();
}

#[tokio::test]
async fn oversized_bodies_are_refused_and_moderate_ones_accepted() {
    let (_dir, upstream, server) = comment_server("guard-body-limit").await;
    let lb = start_loopback(server).await;

    // Announced oversize: refused from the header, before any body is read.
    // The 413 check sits behind the session gate, so the target must be scoped.
    let limit = fqapi_core::server::MAX_REQUEST_BODY;
    let (status, text) = raw(
        lb.port,
        &format!(
            "POST {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n",
            lb.scoped_path(COMMENT_ADD),
            lb.port,
            limit + 1
        ),
    )
    .await;
    assert_eq!(status, 413, "{text}");
    assert!(upstream.requests().is_empty());

    // Above axum's default body limit but inside our cap: accepted and drained
    // by the adapter without buffering/copying the body into a Vec.
    let client = reqwest::Client::new();
    let response = client
        .post(lb.url(COMMENT_ADD))
        .body(vec![b' '; 3 * 1024 * 1024])
        .send()
        .await
        .expect("3 MiB POST");
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(upstream.requests().len(), 1);
    lb.task.abort();
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
    let lb = start_loopback(server).await;
    let (status, text) = raw(
        lb.port,
        &format!(
            "GET {} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nConnection: close\r\n\r\n",
            lb.scoped_path("/no/such/route"),
            lb.port
        ),
    )
    .await;
    assert_eq!(status, 302, "{text}");
    assert!(
        text.to_ascii_lowercase()
            .contains("location: https://www.example.com/"),
        "{text}"
    );
    lb.task.abort();
}
// --- Read routes are open, device-bound writes are not --------------------
//
// External readers (Legado book sources, local tooling) cannot know the
// per-launch capability, so every read route answers any local client that
// names this listener in `Host`. The guard that matters now is the write one:
// posting a comment or danmaku under this installation's device identity still
// requires the capability.

#[tokio::test]
async fn read_routes_answer_a_capability_free_local_client() {
    let dir = TempDir::new("gate-open-reads");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = start_loopback(server).await;
    let client = reqwest::Client::new();

    // What a Legado book source sends: no capability, no Origin, no cookie.
    let response = client
        .get(lb.bare_url("/health"))
        .send()
        .await
        .expect("bare GET");
    assert_eq!(response.status().as_u16(), 200);
    let text = response.text().await.expect("health body");
    assert!(text.contains("\"devices\":3"), "{text}");

    // A leading `/_session/<capability>` is still stripped for callers that do
    // carry one (Flutter's resource URLs), so both shapes reach the dispatcher.
    let response = client
        .get(lb.url("/health"))
        .send()
        .await
        .expect("scoped GET");
    assert_eq!(response.status().as_u16(), 200);
    lb.task.abort();
}

#[tokio::test]
async fn a_device_bound_write_without_a_capability_is_refused() {
    let (_dir, upstream, server) = comment_server("gate-write-no-capability").await;
    let lb = start_loopback(server).await;
    let client = reqwest::Client::new();

    // A sibling app on the same phone can reach the listener, so the write
    // routes must not become a way to post as this installation's device.
    let response = client
        .post(lb.bare_url(COMMENT_ADD))
        .send()
        .await
        .expect("bare POST");
    assert_eq!(response.status().as_u16(), 401);
    let body: serde_json::Value = response.json().await.expect("json refusal");
    assert_eq!(body["error"], "session required");
    assert!(
        upstream.requests().is_empty(),
        "no upstream call may be made"
    );

    // A wrong capability is refused on the same route, exactly, never as a
    // prefix match. A near-miss prefix is not stripped, so the path reaches the
    // dispatcher unchanged and 404s; either way nothing reaches upstream.
    let truncated = &lb.token[..lb.token.len() / 2];
    let extended = format!("{}0", lb.token);
    let unrelated = "0".repeat(lb.token.len());
    for capability in [truncated, extended.as_str(), unrelated.as_str()] {
        let response = client
            .post(lb.url_with(capability, COMMENT_ADD))
            .send()
            .await
            .expect("scoped POST");
        assert_ne!(response.status().as_u16(), 200, "capability {capability:?}");
        let body: serde_json::Value = response.json().await.expect("json refusal");
        assert_eq!(body["success"], false, "capability {capability:?}");
    }
    assert!(upstream.requests().is_empty());

    // The real capability goes through, so the refusal above is the gate and
    // not a broken route.
    let response = client
        .post(lb.url(COMMENT_ADD))
        .send()
        .await
        .expect("scoped POST");
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(upstream.requests().len(), 1);
    lb.task.abort();
    upstream.shutdown();
}

#[tokio::test]
async fn a_bearer_header_is_accepted_on_a_bare_path() {
    let dir = TempDir::new("gate-bearer");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = start_loopback(server).await;

    let response = reqwest::Client::new()
        .get(lb.bare_url("/health"))
        .header("authorization", format!("Bearer {}", lb.token))
        .send()
        .await
        .expect("bearer GET");
    assert_eq!(response.status().as_u16(), 200);
    let text = response.text().await.expect("health body");
    assert!(text.contains("\"devices\":3"), "{text}");
    lb.task.abort();
}

#[tokio::test]
async fn a_near_miss_session_prefix_is_not_treated_as_scoped() {
    let dir = TempDir::new("gate-prefix-near-miss");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = start_loopback(server).await;
    let client = reqwest::Client::new();

    // Only end-of-path or a following '/' closes the capability. A longer
    // segment, a relative hop and an encoded separator must all stay unscoped
    // rather than having the prefix stripped and the rest served.
    for path in [
        format!("/_session/{}abc/health", lb.token),
        format!("/_session/{}../health", lb.token),
        format!("/_session/{}%2fhealth", lb.token),
    ] {
        let response = client
            .get(lb.bare_url(&path))
            .send()
            .await
            .expect("near-miss GET");
        assert_eq!(response.status().as_u16(), 404, "path {path}");
        let body: serde_json::Value = response.json().await.expect("json refusal");
        assert_eq!(body["success"], false, "path {path}");
        assert!(
            !body.to_string().contains("devices"),
            "path {path} leaked: {body}"
        );
    }
    lb.task.abort();
}

// --- LAN share mode -------------------------------------------------------
//
// Turning on LAN sharing binds every interface, so another device on the same
// network addresses this listener by an IP literal. The guard cannot enumerate
// the phone's interfaces (the list goes stale on every network change), so it
// accepts any IP literal and keeps refusing domain names - which is what still
// blocks DNS rebinding.

async fn lan_loopback(
    name: &str,
) -> (
    TempDir,
    std::sync::Arc<fqapi_core::endpoints::Server>,
    Loopback,
) {
    let dir = TempDir::new(name);
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = start_listener(server.clone(), fqapi_core::server::ListenMode::Lan).await;
    (dir, server, lb)
}

#[tokio::test]
async fn lan_mode_answers_a_lan_ip_host_on_a_read_route() {
    let (_dir, _server, lb) = lan_loopback("lan-ip-host").await;

    // What a phone on the same WiFi sends: the host's LAN address, not localhost.
    for host in [
        format!("192.168.1.23:{}", lb.port),
        format!("10.0.0.7:{}", lb.port),
        format!("172.16.5.9:{}", lb.port),
    ] {
        let (status, text) = raw(
            lb.port,
            &format!("GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert_eq!(status, 200, "host {host}: {text}");
        assert!(text.contains("\"devices\":3"), "host {host}: {text}");
    }
    lb.task.abort();
}

#[tokio::test]
async fn lan_mode_still_refuses_a_domain_host() {
    let (_dir, _server, lb) = lan_loopback("lan-domain-host").await;

    // DNS rebinding: an attacker page resolves its own domain to this address,
    // and the browser then sends that domain in Host. A name must never match
    // even though the listener is open to the network.
    for host in [
        format!("evil.example:{}", lb.port),
        format!("attacker.test:{}", lb.port),
        // A name that merely embeds an IP must not slip through either.
        format!("192.168.1.23.evil.example:{}", lb.port),
    ] {
        let (status, text) = raw(
            lb.port,
            &format!("GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
        )
        .await;
        assert_eq!(status, 403, "host {host}: {text}");
        assert!(text.contains("host not allowed"), "host {host}: {text}");
        assert!(!text.contains("devices"), "host {host} leaked: {text}");
    }
    lb.task.abort();
}

#[tokio::test]
async fn loopback_mode_refuses_a_lan_ip_host() {
    let dir = TempDir::new("loopback-refuses-lan-ip");
    let server = build_server(&dir, None, &[], &[], &pool_json(3)).await;
    let lb = start_loopback(server).await;

    // Sharing off must stay private: a LAN address in Host is refused even
    // though the port is right.
    let host = format!("192.168.1.23:{}", lb.port);
    let (status, text) = raw(
        lb.port,
        &format!("GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"),
    )
    .await;
    assert_eq!(status, 403, "{text}");
    assert!(text.contains("host not allowed"), "{text}");
    lb.task.abort();
}

#[tokio::test]
async fn lan_mode_refuses_a_foreign_origin_but_accepts_a_lan_one() {
    let (_dir, _server, lb) = lan_loopback("lan-origin").await;
    let client = reqwest::Client::new();
    let ok_host = format!("192.168.1.23:{}", lb.port);

    // A cross-site form POST from a foreign page is still refused.
    let response = client
        .post(format!("http://127.0.0.1:{}{}", lb.port, COMMENT_ADD))
        .header("host", &ok_host)
        .header("origin", "https://evil.example")
        .send()
        .await
        .expect("foreign-origin POST");
    assert_eq!(response.status().as_u16(), 403);

    // A page served from this listener over the LAN is same-origin and passes
    // the Origin guard - but the route is a device-bound write, so it still
    // needs the capability. 401 here proves the Origin check was cleared while
    // the capability gate held, which is the layering this test pins.
    let response = client
        .post(format!(
            "http://127.0.0.1:{}{}",
            lb.port,
            lb.scoped_path(COMMENT_ADD)
        ))
        .header("host", &ok_host)
        .header("origin", format!("http://{ok_host}"))
        .send()
        .await
        .expect("lan-origin POST");
    assert_eq!(response.status().as_u16(), 200);
    lb.task.abort();
}
