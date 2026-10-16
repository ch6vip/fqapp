//! Thin wrapper around the shared reqwest client.
//!
//! Deliberately does NOT use reqwest's gzip feature: the reference implementation only
//! decompresses when the transport itself asked for gzip (or when the body
//! carries the gzip magic), and some endpoints set `Accept-Encoding` by hand.
//! Redirect policy and business-error handling therefore stay identical too.

use std::time::Duration;

use futures::StreamExt;

use crate::crypto::{gunzip_capped, GunzipError, MAX_GUNZIP_BYTES};

/// Response-body cap for JSON/API calls (P2-12). The video download path
/// (`video.rs` unsigned_get) deliberately does not use it — it streams
/// through the uncapped `request` until its own streaming fix lands, so a
/// 64 MiB cap here must never apply to media bytes.
pub const API_BODY_LIMIT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct RawResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RawResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone)]
pub enum TransportError {
    /// Connection-level failure (Go: `http.Client.Do` error).
    Network(String),
}

pub struct HttpTransport {
    client: reqwest::Client,
    timeout: Duration,
}

impl HttpTransport {
    pub fn new(timeout_secs: u64) -> Result<Self, String> {
        ensure_crypto_provider();
        let tls = build_tls_config()?;
        let client = reqwest::Client::builder()
            .tls_backend_preconfigured(tls)
            .build()
            .map_err(|e| format!("build http client: {e}"))?;
        Ok(HttpTransport {
            client,
            timeout: Duration::from_secs(timeout_secs),
        })
    }

    /// Uncapped request. Only the video download path uses this (see
    /// [API_BODY_LIMIT_BYTES]); every JSON/API caller must use
    /// [HttpTransport::request_with_limit].
    pub async fn request(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
    ) -> Result<RawResponse, TransportError> {
        self.request_with_limit(method, url, headers, body, timeout, None)
            .await
    }

    /// Request whose response body is rejected once it exceeds
    /// `body_limit` (when `Some`). The body is streamed chunk by chunk, so
    /// an over-limit response fails before its full bytes are ever buffered.
    pub async fn request_with_limit(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
        body_limit: Option<usize>,
    ) -> Result<RawResponse, TransportError> {
        let m = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|e| TransportError::Network(format!("bad method {method}: {e}")))?;
        let mut builder = self
            .client
            .request(m, url)
            .timeout(timeout.unwrap_or(self.timeout));
        if !headers.is_empty() {
            let mut map = reqwest::header::HeaderMap::new();
            for (k, v) in headers {
                if let (Ok(name), Ok(value)) = (
                    reqwest::header::HeaderName::from_bytes(k.as_bytes()),
                    reqwest::header::HeaderValue::from_str(v),
                ) {
                    map.insert(name, value);
                }
            }
            builder = builder.headers(map);
        }
        if let Some(b) = body {
            builder = builder.body(b);
        }

        let resp = builder
            .send()
            .await
            .map_err(|e| TransportError::Network(e.to_string()))?;
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
        // Stream the body with the caller's cap enforced per chunk: an
        // over-limit response is rejected before it is fully buffered.
        let mut body = Vec::new();
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| TransportError::Network(e.to_string()))?;
            body.extend_from_slice(&chunk);
            if let Some(limit) = body_limit {
                if body.len() > limit {
                    return Err(TransportError::Network(format!(
                        "response body exceeds {limit} bytes"
                    )));
                }
            }
        }

        let gzip_header = headers.iter().any(|(k, v)| {
            k.eq_ignore_ascii_case("content-encoding") && v.eq_ignore_ascii_case("gzip")
        });
        let gzip_magic = body.len() >= 2 && body[0] == 0x1f && body[1] == 0x8b;
        if gzip_header || gzip_magic {
            match gunzip_capped(&body, MAX_GUNZIP_BYTES) {
                Ok(inflated) => body = inflated,
                // A gzip bomb is a hard failure, never a silent pass-through.
                Err(GunzipError::OverLimit) => {
                    return Err(TransportError::Network(format!(
                        "gunzip output exceeds {MAX_GUNZIP_BYTES} bytes"
                    )));
                }
                // Corrupt gzip keeps the old behavior: the compressed bytes
                // flow downstream, where JSON parsing rejects them.
                Err(GunzipError::Corrupt(_)) => {}
            }
        }

        Ok(RawResponse {
            status,
            headers,
            body,
        })
    }
}

/// reqwest is built with `rustls-no-provider` so exactly one TLS backend is
/// linked; that means the process-wide crypto provider has to be installed
/// before any client is constructed. Installing it here keeps the requirement
/// with the only code that needs it.
fn ensure_crypto_provider() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn build_tls_config() -> Result<rustls::ClientConfig, String> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = std::sync::Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| format!("tls protocol versions: {e}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(config)
}

#[cfg(test)]
mod body_cap_tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// Serves one fixed response, then exits. Returns the URL to fetch.
    fn serve_once(body: Vec<u8>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = [0u8; 8192];
                let _ = stream.read(&mut buf);
                let header = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes());
                let _ = stream.write_all(&body);
                let _ = stream.flush();
            }
        });
        format!("http://{addr}/api/x")
    }

    fn run<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(f)
    }

    #[test]
    fn over_limit_body_is_rejected() {
        let url = serve_once(vec![b'x'; 1024 * 1024]);
        let transport = HttpTransport::new(5).expect("transport");
        let err = run(transport.request_with_limit("GET", &url, &[], None, None, Some(1024)))
            .expect_err("1 MiB body must exceed a 1 KiB cap");
        assert!(matches!(err, TransportError::Network(_)));
    }

    #[test]
    fn under_limit_body_passes_through() {
        let url = serve_once(b"{\"ok\":true}".to_vec());
        let transport = HttpTransport::new(5).expect("transport");
        let resp = run(transport.request_with_limit("GET", &url, &[], None, None, Some(1024)))
            .expect("small body passes");
        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, b"{\"ok\":true}");
    }
}
