//! Loopback HTTP adapter.
//!
//! Serves the built-in Web UI, `/src/*` decrypted manga images and the
//! `/api/*` Web bridge to the same dispatcher the FFI bridge uses, so there is
//! exactly one business implementation.
//!
//! Static file bodies are streamed from disk (with Range support) instead of
//! being read into memory, so serving a large media file costs a bounded
//! buffer rather than its full size.

use std::sync::Arc;

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Router;
use tokio_util::io::ReaderStream;

use crate::dispatch::{dispatch, Request, ResponseBody};
use crate::endpoints::Server;

pub struct LoopbackHandle {
    pub port: u16,
    pub task: tokio::task::JoinHandle<()>,
}

pub async fn serve(server: Arc<Server>, port: u16) -> Result<LoopbackHandle, String> {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|e| format!("listen 127.0.0.1:{port}: {e}"))?;
    let local = listener
        .local_addr()
        .map_err(|e| format!("local addr: {e}"))?;
    let app = Router::new().fallback(handler).with_state(server);
    let task = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    Ok(LoopbackHandle {
        port: local.port(),
        task,
    })
}

async fn handler(State(server): State<Arc<Server>>, req: axum::extract::Request) -> Response {
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
    let body = axum::body::to_bytes(req.into_body(), 64 * 1024 * 1024)
        .await
        .unwrap_or_default();
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
