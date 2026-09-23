//! Network side of device registration.
//! Port of `/internal/device/register.go`.

use md5::{Digest, Md5};
use serde_json::{json, Value};

use crate::crypto::gzip;
use crate::device::crypto::*;
use crate::device::Device;
use crate::sign::Manager;
use crate::upstream::http::HttpTransport;

const PKG_NAME: &str = "com.dragon.read";
const SDK_VERSION: &str = "v04.04.05-ov-android";

/// Go's `url.Values.Encode()`: sorted keys, query-component escaping with '+'
/// for spaces and the unreserved set `A-Za-z0-9-_.~`.
pub fn go_query_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub fn sorted_query(params: &[(String, String)]) -> String {
    let mut v = params.to_vec();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v.iter()
        .map(|(k, val)| format!("{}={}", go_query_escape(k), go_query_escape(val)))
        .collect::<Vec<_>>()
        .join("&")
}

#[derive(Debug, Clone)]
pub struct DevInfo {
    pub device_type: String,
    pub os_api: String,
    pub os_version: String,
    pub openudid: String,
    pub resolution: String,
    pub dpi: String,
    pub cdid: String,
    pub uuid: String,
    pub clientudid: String,
    pub rom: String,
    pub rom_version: String,
    pub device_brand: String,
    pub channel: String,
    pub version_code: String,
    pub version_name: String,
    pub manifest_version_code: String,
    pub update_version_code: String,
    pub user_agent: String,
}

pub fn new_dev_info() -> DevInfo {
    let openudid = random_hex_lower(16);
    let version_name = "6.5.1.32".to_string();
    let mut di = DevInfo {
        device_type: "MI 12".into(),
        os_api: "29".into(),
        os_version: "10".into(),
        openudid,
        resolution: "1440*2392".into(),
        dpi: "560".into(),
        cdid: uuid_v4(),
        uuid: uuid_v4(),
        clientudid: uuid_v4(),
        rom: String::new(),
        rom_version: String::new(),
        device_brand: "Xiaomi".into(),
        channel: "xiaomi_1967_64".into(),
        version_code: "65132".into(),
        version_name,
        manifest_version_code: "65132".into(),
        update_version_code: "65132".into(),
        user_agent: String::new(),
    };
    di.rom = format!("EMUI-{}", String::from_utf8_lossy(&random_alnum(13)));
    di.rom_version = String::from_utf8_lossy(&random_alnum(2)).into_owned();
    let tt_net = "TTNetVersion:9ac8d95c 2024-11-25 QuicVersion:3f326df4 2024-11-14";
    di.user_agent = format!(
        "com.dragon.read/{} (Linux; U; Android {}; zh_CN; {}; Build/MMB29M; Cronet/{})",
        di.manifest_version_code, di.os_version, di.device_type, tt_net
    );
    di
}

impl DevInfo {
    pub fn url_params(&self, extra: &[(String, String)]) -> Vec<(String, String)> {
        let now = crate::timeutil::now_secs().to_string();
        let mut p: Vec<(String, String)> = vec![
            ("tt_data".into(), "a".into()),
            ("os_api".into(), self.os_api.clone()),
            ("device_type".into(), self.device_type.clone()),
            ("ssmix".into(), "a".into()),
            (
                "manifest_version_code".into(),
                self.manifest_version_code.clone(),
            ),
            ("dpi".into(), self.dpi.clone()),
            ("version_name".into(), self.version_name.clone()),
            ("ts".into(), now),
            ("cpu_support64".into(), "true".into()),
            ("app_type".into(), "normal".into()),
            ("appTheme".into(), "light".into()),
            ("ac".into(), "wifi".into()),
            ("host_abi".into(), "arm64-v8a".into()),
            (
                "update_version_code".into(),
                self.update_version_code.clone(),
            ),
            ("channel".into(), self.channel.clone()),
            ("_rticket".into(), crate::timeutil::now_millis().to_string()),
            ("device_platform".into(), "android".into()),
            ("version_code".into(), self.version_code.clone()),
            ("cdid".into(), self.cdid.clone()),
            ("os".into(), "android".into()),
            ("is_android_pad".into(), "0".into()),
            ("openudid".into(), self.openudid.clone()),
            ("package".into(), PKG_NAME.into()),
            ("resolution".into(), self.resolution.clone()),
            ("os_version".into(), self.os_version.clone()),
            ("language".into(), "zh".into()),
            ("device_brand".into(), self.device_brand.clone()),
            ("need_personal_recommend".into(), "1".into()),
            ("aid".into(), "1967".into()),
            ("minor_status".into(), "0".into()),
            ("app_name".into(), "novel".into()),
            ("mcc_mnc".into(), "46007".into()),
        ];
        for (k, v) in extra {
            p.retain(|(pk, _)| pk != k);
            p.push((k.clone(), v.clone()));
        }
        p
    }
}

pub struct Registrar {
    http: HttpTransport,
    sign: Manager,
    /// Offline test seam, see `UpstreamClient::with_mock_origin`.
    mock_origin: Option<String>,
}

impl Registrar {
    pub fn new() -> Result<Self, String> {
        Self::build(None)
    }

    pub fn with_mock_origin(origin: impl Into<String>) -> Result<Self, String> {
        Self::build(Some(origin.into()))
    }

    fn build(mock_origin: Option<String>) -> Result<Self, String> {
        let mut sign = Manager::new();
        // registerKey signs with x-gorgon enabled.
        sign.enable_gorgon = true;
        Ok(Registrar {
            http: HttpTransport::new(30)?,
            sign,
            mock_origin,
        })
    }

    fn target(&self, url: &str) -> String {
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

    /// Full registration: device_register -> app_alert_check -> privilege
    /// activation -> registerkey.
    pub async fn register(&self) -> Result<Device, String> {
        let di = new_dev_info();

        let (device_id, install_id) = self
            .device_register(&di)
            .await
            .map_err(|e| format!("device_register: {e}"))?;

        let _ = self.app_alert_check(&di, &device_id, &install_id).await;
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        let _ = self
            .activate_premium(&device_id, &install_id, &di.device_type)
            .await;

        let secret_key = match self.register_key(&device_id, &install_id).await {
            Ok(k) => k,
            Err(e) => {
                log_line(&format!(
                    "registerKey failed (secret_key will be empty): {e}"
                ));
                String::new()
            }
        };

        let now = crate::timeutil::now_string();
        Ok(Device {
            device_id,
            install_id,
            secret_key,
            platform: "android".into(),
            status: "active".into(),
            created_time: now.clone(),
            last_used: now,
            use_count: 0,
            cdid: di.cdid,
        })
    }

    async fn device_register(&self, di: &DevInfo) -> Result<(String, String), String> {
        let gtime = crate::timeutil::now_millis();
        let header = json!({
            "display_name": "番茄小说",
            "update_version_code": di.update_version_code,
            "manifest_version_code": di.manifest_version_code,
            "aid": 1967,
            "channel": di.channel,
            "package": PKG_NAME,
            "app_version": di.version_name,
            "version_code": di.version_code,
            "sdk_version": SDK_VERSION,
            "sdk_target_version": 29,
            "os": "Android",
            "os_version": di.os_version,
            "os_api": di.os_api,
            "device_model": di.device_type,
            "device_brand": di.device_brand,
            "device_manufacturer": "Google",
            "device_category": "phone",
            "cpu_abi": "arm64-v8a",
            "release_build": uuid_v4(),
            "density_dpi": di.dpi,
            "display_density": "mdpi",
            "resolution": di.resolution.replace('*', "x"),
            "language": "zh",
            "mac": rand_mac(),
            "timezone": 8,
            "access": "wifi",
            "not_request_sender": 0,
            "carrier": "CHINA MOBILE",
            "mcc_mnc": "46007",
            "rom": di.rom,
            "rom_version": di.rom_version,
            "sig_hash": md5_hex(&uuid_v4()),
            "openudid": di.openudid,
            "clientudid": di.clientudid,
            "sim_serial_number": [],
            "region": "CN",
            "tz_name": "Asia/Shanghai",
            "tz_offset": 28800,
            "sim_region": "cn",
        });
        let body = json!({
            "magic_tag": "ss_app_log",
            "header": header,
            "_gen_time": gtime,
        });
        let json_data = serde_json::to_vec(&body).map_err(|e| e.to_string())?;
        let gz = gzip(&json_data);
        let post_data = tt_encrypt(&gz, None)?;

        let params = di.url_params(&[]);
        let req_url = format!(
            "https://log.snssdk.com/service/2/device_register/?{}",
            sorted_query(&params)
        );

        let headers = vec![
            (
                "content-type".to_string(),
                "application/octet-stream;tt-data=a".to_string(),
            ),
            ("accept-encoding".to_string(), "gzip".to_string()),
            ("user-agent".to_string(), di.user_agent.clone()),
            ("host".to_string(), "log.snssdk.com".to_string()),
            ("connection".to_string(), "Keep-Alive".to_string()),
        ];

        let resp = self
            .http
            .request(
                "POST",
                &self.target(&req_url),
                &headers,
                Some(post_data),
                None,
            )
            .await
            .map_err(|e| format!("{e:?}"))?;
        if resp.status != 200 {
            return Err(format!("HTTP {}", resp.status));
        }
        let raw = resp.body;
        let rd: Value = serde_json::from_slice(&raw).map_err(|e| format!("json: {e}"))?;
        let device_id = pick_str(&rd, &["device_id_str", "device_id"]);
        let install_id = pick_str(&rd, &["install_id_str", "install_id"]);
        if device_id.is_empty() || install_id.is_empty() {
            return Err(format!("bad response: {}", String::from_utf8_lossy(&raw)));
        }
        Ok((device_id, install_id))
    }

    async fn app_alert_check(
        &self,
        di: &DevInfo,
        device_id: &str,
        install_id: &str,
    ) -> Result<(), String> {
        let params = di.url_params(&[
            ("device_id".to_string(), device_id.to_string()),
            ("iid".to_string(), install_id.to_string()),
        ]);
        let query = sorted_query(&params);
        let req_url = format!("https://ichannel.snssdk.com/service/2/app_alert_check/?{query}");

        let mut headers = vec![
            (
                "content-type".to_string(),
                "application/octet-stream;tt-data=a".to_string(),
            ),
            ("accept-encoding".to_string(), "gzip".to_string()),
            ("log-encode-type".to_string(), "gzip".to_string()),
            ("x-tt-request-tag".to_string(), "t=0;n=1".to_string()),
            (
                "x-ss-req-ticket".to_string(),
                crate::timeutil::now_millis().to_string(),
            ),
            ("sdk-version".to_string(), "2".to_string()),
            ("passport-sdk-version".to_string(), di.version_code.clone()),
            (
                "x-vc-bdturing-sdk-version".to_string(),
                "3.7.4.cn".to_string(),
            ),
            ("user-agent".to_string(), di.user_agent.clone()),
            ("host".to_string(), "ichannel.snssdk.com".to_string()),
            ("connection".to_string(), "Keep-Alive".to_string()),
        ];
        for (k, v) in self.sign.generate_headers(&query, None) {
            headers.retain(|(hk, _)| !hk.eq_ignore_ascii_case(&k));
            headers.push((k, v));
        }

        let _ = self
            .http
            .request("GET", &self.target(&req_url), &headers, None, None)
            .await;
        Ok(())
    }

    async fn activate_premium(
        &self,
        device_id: &str,
        install_id: &str,
        device_type: &str,
    ) -> Result<(), String> {
        let mut parts = vec![
            "aid=1967".to_string(),
            "app_name=novelapp".to_string(),
            "channel=0".to_string(),
            format!("device_id={device_id}"),
            "device_platform=android".to_string(),
            format!("device_type={device_type}"),
            format!("iid={install_id}"),
            "os_version=0".to_string(),
            "version_code=61532".to_string(),
            "version_name=6.1.5.32".to_string(),
            "manifest_version_code=61532".to_string(),
            "update_version_code=61532".to_string(),
        ];
        parts.sort();
        let req_url = format!(
            "https://api5-normal-sinfonlinea.fqnovel.com/reading/user/privilege/add/v/?{}",
            parts.join("&")
        );

        let body = json!({
            "add_count_daily": 0,
            "amount": 2592000,
            "privilege_id": 7210376203117531962i64,
            "from": 8,
            "unique_key": crate::timeutil::now_millis().to_string(),
        });
        let body_json = serde_json::to_vec(&body).map_err(|e| e.to_string())?;

        let _ = self
            .http
            .request("POST", &self.target(&req_url), &[], Some(body_json), None)
            .await;
        Ok(())
    }

    async fn register_key(&self, device_id: &str, install_id: &str) -> Result<String, String> {
        let content = encrypt_register_key_request(device_id, None)?;

        let mut parts = vec![
            "aid=1967".to_string(),
            "app_name=novelapp".to_string(),
            "channel=0".to_string(),
            format!("device_id={device_id}"),
            "device_platform=android".to_string(),
            format!("iid={install_id}"),
            "os_version=0".to_string(),
            "version_code=6.1.5.32".to_string(),
            "version_name=6.1.5.32".to_string(),
        ];
        parts.sort();
        let param_string = parts.join("&");
        let req_url =
            format!("https://reading.snssdk.com/reading/crypt/registerkey?{param_string}");

        let post_json =
            serde_json::to_vec(&json!({ "content": content })).map_err(|e| e.to_string())?;
        let compressed = gzip(&post_json);
        let sig_headers = self.sign.generate_headers(&param_string, Some(&compressed));

        let mut last_err = String::new();
        for _attempt in 0..3 {
            let mut headers = vec![
                ("User-Agent".to_string(), "com.dragon.read".to_string()),
                ("Content-Encoding".to_string(), "gzip".to_string()),
            ];
            for (k, v) in &sig_headers {
                headers.retain(|(hk, _)| !hk.eq_ignore_ascii_case(k));
                headers.push((k.clone(), v.clone()));
            }

            let resp = match self
                .http
                .request(
                    "POST",
                    &self.target(&req_url),
                    &headers,
                    Some(compressed.clone()),
                    None,
                )
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    last_err = format!("{e:?}");
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    continue;
                }
            };
            if resp.status != 200 {
                last_err = format!(
                    "HTTP {} body={}",
                    resp.status,
                    String::from_utf8_lossy(&resp.body)
                );
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }

            let rd: Value = match serde_json::from_slice(&resp.body) {
                Ok(v) => v,
                Err(e) => {
                    last_err = format!("json: {e}");
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    continue;
                }
            };
            let key = rd
                .get("data")
                .and_then(|d| d.get("key"))
                .and_then(|k| k.as_str())
                .unwrap_or("")
                .to_string();
            if key.is_empty() {
                last_err = "missing key field".to_string();
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }
            match decrypt_register_key(&key) {
                Ok(dec) if !dec.is_empty() => return Ok(hex::encode_upper(dec)),
                Ok(_) => {
                    last_err = "decrypt key: empty".to_string();
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    continue;
                }
                Err(e) => {
                    last_err = format!("decrypt key: {e}");
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    continue;
                }
            }
        }
        Err(last_err)
    }
}

pub fn md5_hex(s: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(s.as_bytes());
    hex::encode(hasher.finalize())
}

fn pick_str(v: &Value, keys: &[&str]) -> String {
    for k in keys {
        if let Some(val) = v.get(*k) {
            if let Some(s) = val.as_str() {
                if !s.is_empty() {
                    return s.to_string();
                }
                continue;
            }
            if let Some(s) = crate::json::value_to_string(val) {
                if !s.is_empty() {
                    return s;
                }
            }
        }
    }
    String::new()
}

fn log_line(msg: &str) {
    let _ = msg;
}
