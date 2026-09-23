//! Upstream request construction shared by all endpoints.
//! Port of `/internal/endpoints/base.go`.

use std::sync::Arc;

use serde_json::Value;

use crate::device::Device;
use crate::error::{ApiError, ApiResult};
use crate::upstream::{ClientError, PinnedDevice, UpstreamClient, UpstreamRequest};

pub const HOST_FQNOVEL: &str = "https://api5-normal-sinfonlineb.fqnovel.com";
pub const HOST_FQNOVELA: &str = "https://api5-normal-sinfonlinea.fqnovel.com";
pub const HOST_FQNOVELB: &str = "https://api5-normal-sinfonlineb.fqnovel.com";
pub const HOST_NOVEL_SNSSDK: &str = "https://novel.snssdk.com";
pub const HOST_READING_SNSSDK: &str = "https://reading.snssdk.com";
pub const HOST_FANQIENOVEL: &str = "https://fanqienovel.com";
pub const UA_DRAGON: &str = "com.dragon.read";
pub const UA_ANDROID_BROWSER: &str = "Mozilla/5.0 (Linux; Android 13)";
pub const UA_WINDOWS_BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
pub const CONTENT_TYPE_JSON: &str = "application/json; charset=utf-8";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpstreamMode {
    DeviceSigned,
    Signed,
    NoSign,
}

#[derive(Debug, Clone)]
pub struct UpstreamRequestSpec {
    pub mode: UpstreamMode,
    pub method: Option<String>,
    pub raw_url: Option<String>,
    pub host: String,
    pub path: String,
    pub params: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
    pub headers: Vec<(String, String)>,
    pub pin_device: String,
}

impl Default for UpstreamRequestSpec {
    fn default() -> Self {
        UpstreamRequestSpec {
            mode: UpstreamMode::Signed,
            method: None,
            raw_url: None,
            host: String::new(),
            path: String::new(),
            params: Vec::new(),
            body: None,
            headers: Vec::new(),
            pin_device: String::new(),
        }
    }
}

pub struct Upstream {
    up: Arc<UpstreamClient>,
}

impl Upstream {
    pub fn new(up: Arc<UpstreamClient>) -> Self {
        Upstream { up }
    }

    fn build(spec: &UpstreamRequestSpec) -> UpstreamRequest {
        let method = match &spec.method {
            Some(m) if !m.is_empty() => Some(m.clone()),
            _ => {
                if spec.body.is_some() {
                    Some("POST".to_string())
                } else {
                    Some("GET".to_string())
                }
            }
        };
        let url = match &spec.raw_url {
            Some(u) if !u.is_empty() => u.clone(),
            _ => crate::endpoints::util::build_upstream_url(&spec.host, &spec.path, &spec.params),
        };
        UpstreamRequest {
            method,
            url,
            body: spec.body.clone(),
            headers: spec.headers.clone(),
            no_sign: spec.mode == UpstreamMode::NoSign,
            pin: if spec.pin_device.is_empty() {
                None
            } else {
                Some(PinnedDevice {
                    device_id: spec.pin_device.clone(),
                })
            },
        }
    }

    pub async fn raw_with_device(
        &self,
        spec: &UpstreamRequestSpec,
    ) -> ApiResult<(Vec<u8>, Device)> {
        let req = Self::build(spec);
        self.up.do_with_device(&req).await.map_err(map_client_error)
    }

    pub async fn raw_with_headers(
        &self,
        spec: &UpstreamRequestSpec,
    ) -> ApiResult<(Vec<u8>, Vec<(String, String)>)> {
        let req = Self::build(spec);
        self.up.do_request(&req).await.map_err(map_client_error)
    }

    pub async fn raw(&self, spec: &UpstreamRequestSpec) -> ApiResult<Vec<u8>> {
        match spec.mode {
            UpstreamMode::DeviceSigned => {
                let (raw, _) = self.raw_with_device(spec).await?;
                Ok(raw)
            }
            UpstreamMode::Signed | UpstreamMode::NoSign => {
                let (raw, _) = self.raw_with_headers(spec).await?;
                Ok(raw)
            }
        }
    }

    pub async fn json(&self, spec: &UpstreamRequestSpec) -> ApiResult<Value> {
        let raw = self.raw(spec).await?;
        crate::endpoints::util::raw_json(&raw)
    }
}

pub fn map_client_error(err: ClientError) -> ApiError {
    match err {
        ClientError::DeviceFailed(m) => ApiError::Internal(format!("device failed: {m}")),
        ClientError::Http(m) => ApiError::Internal(m),
        ClientError::Other(m) => ApiError::Internal(m),
    }
}

pub fn dragon_read_headers() -> Vec<(String, String)> {
    crate::endpoints::util::user_agent_headers(UA_DRAGON)
}

pub fn dragon_read_json_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), UA_DRAGON.to_string()),
        ("Content-Type".to_string(), CONTENT_TYPE_JSON.to_string()),
    ]
}

pub fn phoenix_player_headers() -> Vec<(String, String)> {
    vec![
        (
            "User-Agent".to_string(),
            "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)".to_string(),
        ),
        (
            "Accept".to_string(),
            "application/json; charset=utf-8,application/x-protobuf".to_string(),
        ),
        ("Content-Type".to_string(), "application/json".to_string()),
        ("x-xs-from-web".to_string(), "0".to_string()),
        ("sdk-version".to_string(), "2".to_string()),
    ]
}

pub fn phoenix_player_url() -> String {
    format!(
        "{HOST_FQNOVELB}/novel/player/multi_video_model/v1/?iid={{install_id}}\
&device_id={{device_id}}&ac=wifi&channel=update_64&aid=8662&app_name=novelread&version_code=71332&version_name=7.1.3.32&device_platform=android&os=android&ssmix=a&device_type=25053RT47C&device_brand=Redmi&language=zh&os_api=36&os_version=16&manifest_version_code=71332&resolution=1280*2772&dpi=520&update_version_code=71332&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=71332&compliance_status=0&need_personal_recommend=1&player_so_load=1&is_android_pad_screen=0"
    )
}
