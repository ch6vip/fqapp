//! Thin wrapper around the shared reqwest client.
//!
//! Deliberately does NOT use reqwest's gzip feature: the reference implementation only
//! decompresses when the transport itself asked for gzip (or when the body
//! carries the gzip magic), and some endpoints set `Accept-Encoding` by hand.
//! Redirect policy and business-error handling therefore stay identical too.

use std::time::Duration;

use crate::crypto::gunzip;

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

    pub async fn request(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
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
        let mut body = resp
            .bytes()
            .await
            .map_err(|e| TransportError::Network(e.to_string()))?
            .to_vec();

        let gzip_header = headers.iter().any(|(k, v)| {
            k.eq_ignore_ascii_case("content-encoding") && v.eq_ignore_ascii_case("gzip")
        });
        let gzip_magic = body.len() >= 2 && body[0] == 0x1f && body[1] == 0x8b;
        if gzip_header || gzip_magic {
            if let Some(inflated) = gunzip(&body) {
                body = inflated;
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
