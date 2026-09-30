//! Loopback HTTP adapter.
//!
//! Serves the built-in Web UI, `/src/*` decrypted manga images and the
//! `/api/*` Web bridge to the same dispatcher the FFI bridge uses, so there is
//! exactly one business implementation.
//!
//! Static file bodies are streamed from disk (with Range support) instead of
//! being read into memory, so serving a large media file costs a bounded
//! buffer rather than its full size.
//!
//! Binding to 127.0.0.1 alone does not keep web pages out. Every request must
//! name this listener in `Host` (defeats DNS rebinding, which would otherwise
//! let a foreign page read responses) and, when it carries an `Origin`, come
//! from this listener too (defeats cross-site form POSTs to the device-bound
//! write routes, which read their arguments from the query string and so need
//! no CORS preflight). Other local apps can still send well-formed requests;
//! that needs a per-launch token and is tracked separately. See
//! .agents/notes/implemented/bug-fix/2026-09-30-loopback-host-origin-guard.md.

use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, FromRequest, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Router;
use serde_json::json;
use tokio_util::io::ReaderStream;

use crate::dispatch::{dispatch, Request, ResponseBody};
use crate::endpoints::Server;

/// Largest request body the adapter buffers. Real callers send short JSON.
pub const MAX_REQUEST_BODY: usize = 64 * 1024 * 1024;

pub struct LoopbackHandle {
    pub port: u16,
    pub task: tokio::task::JoinHandle<()>,
}

#[derive(Clone)]
struct AppState {
    server: Arc<Server>,
    /// The bound port, not the requested one: `serve(_, 0)` picks it at bind.
    port: u16,
}

pub async fn serve(server: Arc<Server>, port: u16) -> Result<LoopbackHandle, String> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|e| format!("listen 127.0.0.1:{port}: {e}"))?;
    let local = listener
        .local_addr()
        .map_err(|e| format!("local addr: {e}"))?;
    let state = AppState {
        server,
        port: local.port(),
    };
    // axum's default body limit is 2 MiB; the Bytes extractor below honours
    // this layer instead.
    let app = Router::new()
        .fallback(handler)
        .layer(DefaultBodyLimit::max(MAX_REQUEST_BODY))
        .with_state(state);
    let task = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Ok(LoopbackHandle {
        port: local.port(),
        task,
    })
}

/// `authority` (a `Host` value or the part of an `Origin` after the scheme)
/// names this listener. Hosts compare case-insensitively; the port must be
/// explicit because the listener never runs on 80.
fn is_own_authority(authority: &str, port: u16) -> bool {
    let Some((host, p)) = authority.rsplit_once(':') else {
        return false;
    };
    p.parse::<u16>().ok() == Some(port)
        && (host == "127.0.0.1" || host.eq_ignore_ascii_case("localhost"))
}

fn is_own_origin(origin: &str, port: u16) -> bool {
    origin
        .get(..7)
        .filter(|scheme| scheme.eq_ignore_ascii_case("http://"))
        .is_some_and(|_| is_own_authority(&origin[7..], port))
}

/// Refusal reason, or `None` when the request may be dispatched. A missing
/// `Host` is refused (HTTP/1.1 requires it; every real client sends it). A
/// missing `Origin` is allowed: native clients and same-origin GETs omit it.
/// `Origin: null` (sandboxed frames, file pages) is foreign.
fn refusal(headers: &HeaderMap, port: u16) -> Option<&'static str> {
    let host = headers.get(header::HOST).and_then(|v| v.to_str().ok());
    if !host.is_some_and(|h| is_own_authority(h, port)) {
        return Some("host not allowed");
    }
    if let Some(origin) = headers.get(header::ORIGIN) {
        if !origin.to_str().is_ok_and(|o| is_own_origin(o, port)) {
            return Some("origin not allowed");
        }
    }
    None
}

fn refuse(status: StatusCode, message: &str) -> Response {
    let body =
        serde_json::to_vec(&json!({ "success": false, "error": message })).unwrap_or_default();
    Response::builder()
        .status(status)
        .header(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json; charset=utf-8"),
        )
        .body(Body::from(body))
        .unwrap_or_else(|_| status.into_response())
}

async fn handler(State(state): State<AppState>, req: axum::extract::Request) -> Response {
    // Refuse before touching the body so a foreign page cannot make us buffer.
    if let Some(reason) = refusal(req.headers(), state.port) {
        return refuse(StatusCode::FORBIDDEN, reason);
    }
    let declared = req
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|len| len > MAX_REQUEST_BODY as u64) {
        return refuse(StatusCode::PAYLOAD_TOO_LARGE, "request body too large");
    }

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
    // An unannounced (chunked) oversize body lands here as a 413 rejection;
    // it used to be swallowed and the request dispatched with an empty body.
    let body = match Bytes::from_request(req, &()).await {
        Ok(body) => body,
        Err(rejection) => return refuse(rejection.status(), "failed to read request body"),
    };
    let server = state.server;
    let request = Request {
        method,
        path: uri.path().to_string(),
        query: uri.query().unwrap_or("").to_string(),
        body: body.to_vec(),
        headers,
    };
    let resp = dispatch(&server, &request).await;

    let status = StatusCode::from_u16(resp.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = Response::builder().status(status).header(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&resp.content_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    for (name, value) in &resp.headers {
        if let (Ok(n), Ok(v)) = (
            header::HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            builder = builder.header(n, v);
        }
    }

    match resp.body {
        ResponseBody::Bytes(bytes) => builder
            .body(Body::from(bytes))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
        ResponseBody::File {
            path,
            offset,
            length,
            ..
        } => match stream_file(&path, offset, length).await {
            Ok(body) => builder
                .body(body)
                .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response()),
            Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        },
    }
}

async fn stream_file(path: &std::path::Path, offset: u64, length: u64) -> Result<Body, String> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    if offset > 0 {
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| e.to_string())?;
    }
    let limited = file.take(length);
    Ok(Body::from_stream(ReaderStream::with_capacity(
        limited,
        64 * 1024,
    )))
}
