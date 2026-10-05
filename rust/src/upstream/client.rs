//! Signed upstream requests with device-pool rotation.

use std::sync::Arc;
use std::time::Duration;

use crate::device::{Device, DevicePool};
use crate::sign::Manager;
use crate::upstream::http::{HttpTransport, TransportError};

pub const DEFAULT_USER_AGENT: &str = "com.dragon.read/66732 (Linux; U; Android 10; zh_CN; Pixel 4 XL; Build/QD1A.190821.007;tt-ok/3.12.13.4-tiktok)";

/// HTTP codes treated as device-auth failures.
fn is_auth_fail_status(status: u16) -> bool {
    matches!(status, 401 | 403 | 10001 | 10002)
}

#[derive(Debug, Clone)]
pub enum ClientError {
    /// Network failure or auth-class status: triggers device replacement.
    DeviceFailed(String),
    Http(String),
    Other(String),
}

impl ClientError {
    pub fn is_device_failed(&self) -> bool {
        matches!(self, ClientError::DeviceFailed(_))
    }
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::DeviceFailed(m) => write!(f, "device failed: {m}"),
            ClientError::Http(m) => f.write_str(m),
            ClientError::Other(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for ClientError {}

/// Reuses a specific pooled device (identified by device_id) instead of drawing
/// the next one from the rotation.
#[derive(Debug, Clone)]
pub struct PinnedDevice {
    pub device_id: String,
}

/// One signed upstream call. `body = None` means GET.
#[derive(Debug, Clone, Default)]
pub struct UpstreamRequest {
    pub method: Option<String>,
    pub url: String,
    pub body: Option<Vec<u8>>,
    pub headers: Vec<(String, String)>,
    pub no_sign: bool,
    pub pin: Option<PinnedDevice>,
}

pub struct UpstreamClient {
    http: HttpTransport,
    sign: Manager,
    pool: Arc<DevicePool>,
    max_retries: usize,
    /// Offline test seam: when set, every absolute upstream URL has its origin
    /// (scheme://host[:port]) replaced by this one. Path and query - and
    /// therefore every signature input - are untouched, so a local mock server
    /// can answer real signed requests without touching the network.
    mock_origin: Option<String>,
}

impl UpstreamClient {
    pub fn new(pool: Arc<DevicePool>, sign: Manager) -> Result<Self, String> {
        Self::build(pool, sign, None)
    }

    /// Builds a client whose upstream calls are redirected to `origin`.
    pub fn with_mock_origin(
        pool: Arc<DevicePool>,
        sign: Manager,
        origin: impl Into<String>,
    ) -> Result<Self, String> {
        Self::build(pool, sign, Some(origin.into()))
    }

    fn build(
        pool: Arc<DevicePool>,
        sign: Manager,
        mock_origin: Option<String>,
    ) -> Result<Self, String> {
        Ok(UpstreamClient {
            http: HttpTransport::new(15)?,
            sign,
            pool,
            max_retries: 3,
            mock_origin,
        })
    }

    /// Applies the mock-origin rewrite, keeping path and query intact.
    fn effective_url(&self, url: &str) -> String {
        let Some(origin) = self.mock_origin.as_deref() else {
            return url.to_string();
        };
        match url::Url::parse(url) {
            Ok(parsed) => {
                let origin = origin.trim_end_matches('/');
                let mut out = format!("{origin}{}", parsed.path());
                if let Some(q) = parsed.query() {
                    out.push('?');
                    out.push_str(q);
                }
                out
            }
            Err(_) => url.to_string(),
        }
    }

    /// Performs a request with signature injection but no device retry.
    pub async fn do_request(
        &self,
        req: &UpstreamRequest,
    ) -> Result<(Vec<u8>, Vec<(String, String)>), ClientError> {
        self.do_resp(req).await
    }

    async fn do_resp(
        &self,
        req: &UpstreamRequest,
    ) -> Result<(Vec<u8>, Vec<(String, String)>), ClientError> {
        let target = self.effective_url(&req.url);
        let parsed =
            url::Url::parse(&target).map_err(|e| ClientError::Other(format!("parse url: {e}")))?;

        let method = match &req.method {
            Some(m) if !m.is_empty() => m.clone(),
            _ => {
                if req.body.is_some() {
                    "POST".to_string()
                } else {
                    "GET".to_string()
                }
            }
        };

        let mut headers: Vec<(String, String)> =
            vec![("User-Agent".to_string(), DEFAULT_USER_AGENT.to_string())];
        for (k, v) in &req.headers {
            headers.retain(|(hk, _)| !hk.eq_ignore_ascii_case(k));
            headers.push((k.clone(), v.clone()));
        }

        if !req.no_sign {
            let sig = self
                .sign
                .generate_headers(parsed.query().unwrap_or(""), req.body.as_deref());
            for (k, v) in sig {
                headers.retain(|(hk, _)| !hk.eq_ignore_ascii_case(&k));
                headers.push((k, v));
            }
        }

        let resp = self
            .http
            .request(&method, &target, &headers, req.body.clone(), None)
            .await
            .map_err(|e| match e {
                TransportError::Network(m) => ClientError::DeviceFailed(m),
            })?;

        if resp.status != 200 {
            if is_auth_fail_status(resp.status) {
                return Err(ClientError::DeviceFailed(format!("HTTP {}", resp.status)));
            }
            return Err(ClientError::Http(format!("HTTP {}", resp.status)));
        }
        Ok((resp.body, resp.headers))
    }

    /// Fetches a device, substitutes placeholders, signs, and retries with a
    /// fresh device on device-class failures.
    pub async fn do_with_device(
        &self,
        req: &UpstreamRequest,
    ) -> Result<(Vec<u8>, Device), ClientError> {
        let mut last_err: Option<ClientError> = None;
        let mut pin = req.pin.clone();

        for _attempt in 0..self.max_retries {
            let mut next_pin = pin.clone();
            let dev = match &next_pin {
                Some(p) => match self.pool.get_by_id(&p.device_id).await {
                    Ok(d) => d,
                    Err(_) => {
                        // A pin miss (device rotated out) falls back to the
                        // pool rotation on the next attempt.
                        next_pin = None;
                        self.pool
                            .get()
                            .await
                            .map_err(|e| ClientError::Other(format!("get device: {e}")))?
                    }
                },
                None => self
                    .pool
                    .get()
                    .await
                    .map_err(|e| ClientError::Other(format!("get device: {e}")))?,
            };

            let mut attempt = req.clone();
            attempt.url = substitute_device(&req.url, &dev);
            attempt.pin = None;

            match self.do_request(&attempt).await {
                Ok((data, _)) => return Ok((data, dev)),
                Err(err) => {
                    last_err = Some(err.clone());
                    if err.is_device_failed() {
                        let _ = self.pool.replace_failed(&dev.device_id).await;
                        pin = None;
                        tokio::time::sleep(Duration::from_millis(100)).await;
                        continue;
                    }
                    return Err(err);
                }
            }
        }
        Err(ClientError::Other(format!(
            "device request failed after {} retries: {}",
            self.max_retries,
            last_err.map(|e| e.to_string()).unwrap_or_default()
        )))
    }
}

pub fn substitute_device(raw_url: &str, dev: &Device) -> String {
    raw_url
        .replace("{device_id}", &dev.device_id)
        .replace("{install_id}", &dev.install_id)
        .replace("{secret_key}", &dev.secret_key)
        .replace("{cdid}", &dev.cdid)
}
