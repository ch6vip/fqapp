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
//! no CORS preflight). A fresh capability protects every route from other
//! local apps. See .agents/notes/implemented/bug-fix/2026-10-07-loopback-session.md.

use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Router;
use rand::RngCore;
use serde_json::json;
use tokio_util::io::ReaderStream;

use crate::dispatch::{dispatch, Request, ResponseBody};
use crate::endpoints::Server;

/// Largest request body accepted by the adapter. Routes currently read their
/// arguments from the URL; accepted bodies are streamed and discarded.
pub const MAX_REQUEST_BODY: usize = 64 * 1024 * 1024;

pub struct LoopbackHandle {
    pub port: u16,
    pub token: String,
    pub task: tokio::task::JoinHandle<()>,
}

#[derive(Clone)]
struct AppState {
    server: Arc<Server>,
    /// The bound port, not the requested one: `serve(_, 0)` picks it at bind.
    port: u16,
    token: String,
}

pub async fn serve(server: Arc<Server>, port: u16) -> Result<LoopbackHandle, String> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|e| format!("listen 127.0.0.1:{port}: {e}"))?;
    let local = listener
        .local_addr()
        .map_err(|e| format!("local addr: {e}"))?;
    let mut entropy = [0u8; 32];
    rand::rngs::OsRng
        .try_fill_bytes(&mut entropy)
        .map_err(|_| "session entropy unavailable")?;
    let token = hex::encode(entropy);
    let state = AppState {
        server,
        port: local.port(),
        token: token.clone(),
    };
    let app = Router::new().fallback(handler).with_state(state);
    let task = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Ok(LoopbackHandle {
        port: local.port(),
        token,
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
    // Refuse before touching the body so a foreign page cannot make us read it.
    if let Some(reason) = refusal(req.headers(), state.port) {
        return refuse(StatusCode::FORBIDDEN, reason);
    }
    let prefix = format!("/_session/{}", state.token);
    let path = req.uri().path();
    let scoped = path
        .strip_prefix(&prefix)
        .filter(|rest| rest.is_empty() || rest.starts_with('/'));
    let bearer = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|h| h.to_str().ok());
    let cookie_name = format!("fq_session_{}", state.port);
    let cookie_ok = req
        .headers()
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|h| h.to_str().ok())
        .flat_map(|h| h.split(';'))
        .filter_map(|part| part.trim().split_once('='))
        .any(|(name, value)| name == cookie_name && value == state.token);
    if scoped.is_none() && bearer != Some(format!("Bearer {}", state.token).as_str()) && !cookie_ok
    {
        return refuse(StatusCode::UNAUTHORIZED, "session required");
    }
    let request_path = scoped.unwrap_or(path).to_string();
    let session_cookie = format!(
        "{cookie_name}={}; Path=/; HttpOnly; SameSite=Strict",
        state.token
    );
    // Clean the entry URL before HTML resolves root-relative links or loads
    // remote media. The capability is never embedded in Web UI source.
    if scoped.is_some() && (request_path.is_empty() || request_path == "/") {
        return Response::builder()
            .status(StatusCode::SEE_OTHER)
            .header(header::LOCATION, "/")
            .header(header::SET_COOKIE, session_cookie)
            .header(header::REFERRER_POLICY, "no-referrer")
            .header(header::CACHE_CONTROL, "no-store")
            .body(Body::empty())
            .unwrap();
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
    // The dispatcher and every current endpoint ignore request bodies. Drain
    // them in bounded frames to preserve the size limit without retaining a
    // whole payload or copying it into Request::body.
    if let Err(status) = discard_request_body(req.into_body()).await {
        let message = if status == StatusCode::PAYLOAD_TOO_LARGE {
            "request body too large"
        } else {
            "failed to read request body"
        };
        return refuse(status, message);
    }
    let server = state.server;
    let request = Request {
        method,
        path: request_path,
        query: uri.query().unwrap_or("").to_string(),
        body: Vec::new(),
        headers,
    };
    let resp = dispatch(&server, &request).await;

    let status = StatusCode::from_u16(resp.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
    let mut builder = Response::builder()
        .status(status)
        .header(header::REFERRER_POLICY, "no-referrer")
        .header(header::CACHE_CONTROL, "no-store")
        .header(
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

async fn discard_request_body(mut body: Body) -> Result<(), StatusCode> {
    use http_body_util::BodyExt;

    let mut consumed = 0usize;
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(|_| StatusCode::BAD_REQUEST)?;
        if let Ok(data) = frame.into_data() {
            consumed = consumed.saturating_add(data.len());
            if consumed > MAX_REQUEST_BODY {
                return Err(StatusCode::PAYLOAD_TOO_LARGE);
            }
        }
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Bytes;
    use futures::stream;
    use std::convert::Infallible;

    #[tokio::test]
    async fn chunked_body_over_limit_is_rejected_without_buffering_the_whole_body() {
        let chunk = Bytes::from(vec![0; 1024 * 1024]);
        let chunks =
            (0..=MAX_REQUEST_BODY / chunk.len()).map(move |_| Ok::<_, Infallible>(chunk.clone()));
        let body = Body::from_stream(stream::iter(chunks));

        assert_eq!(
            discard_request_body(body).await,
            Err(StatusCode::PAYLOAD_TOO_LARGE)
        );
    }
}
