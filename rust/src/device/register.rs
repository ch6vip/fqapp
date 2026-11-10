//! Network side of device registration.

use md5::{Digest, Md5};
use serde_json::{json, Value};

use crate::crypto::gzip;
use crate::device::crypto::*;
use crate::device::Device;
use crate::sign::Manager;
use crate::upstream::http::{HttpTransport, API_BODY_LIMIT_BYTES};

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

/// Process-wide holder for the upstream identity.
///
/// It lives here rather than being threaded through every constructor because
/// it is genuinely process-wide: one app version and one UA, no matter which
/// device slot registers.
///
/// Publishing happens on every `init_core`: `BackendService.restartForListenMode`
/// stops and starts the core in the same process, and a config edit has to win
/// there too. A plain `OnceLock` would silently keep the first identity — the
/// bug this holder exists to avoid. A `RwLock` also keeps "read before any init"
/// from pinning the defaults for the rest of the process.
struct IdentityCell {
    slot: std::sync::RwLock<Option<crate::config::UpstreamIdentity>>,
}

impl IdentityCell {
    const fn new() -> Self {
        Self {
            slot: std::sync::RwLock::new(None),
        }
    }

    fn publish(&self, identity: crate::config::UpstreamIdentity) {
        // The write guard only formats nothing and stores a clone, so poisoning
        // is unreachable in practice; if it ever happened, keeping the previous
        // identity is the least surprising outcome.
        if let Ok(mut slot) = self.slot.write() {
            *slot = Some(identity.resolved());
        }
    }

    fn current(&self) -> crate::config::UpstreamIdentity {
        self.slot
            .read()
            .ok()
            .and_then(|slot| slot.clone())
            .unwrap_or_else(|| crate::config::UpstreamIdentity::default().resolved())
    }
}

static IDENTITY: IdentityCell = IdentityCell::new();

pub fn set_upstream_identity(identity: crate::config::UpstreamIdentity) {
    IDENTITY.publish(identity);
}

/// The version code devices are currently registered with.
///
/// The pool records this per device so a changed identity can retire the
/// devices that were registered under the old one.
///
/// This is never empty: an identity that names no version resolves to the
/// built-in default, which is exactly the version code a device registers
/// with when the upstream section is absent. So "no upstream configured" and
/// "the default version" are the same thing here, and the pool compares
/// against the default rather than skipping the comparison.
pub fn current_version_code() -> String {
    IDENTITY.current().version_code
}

pub fn new_dev_info() -> DevInfo {
    dev_info_with(&IDENTITY.current())
}

/// Build the device identity from explicitly supplied upstream parameters.
///
/// Split out from [`new_dev_info`] so tests can exercise the substitution rules
/// without mutating the process-wide cell.
pub fn dev_info_with(identity: &crate::config::UpstreamIdentity) -> DevInfo {
    let identity = identity.resolved();
    let openudid = random_hex_lower(16);
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
        version_code: identity.version_code.clone(),
        version_name: identity.version_name.clone(),
        manifest_version_code: identity.manifest_version_code.clone(),
        update_version_code: identity.update_version_code.clone(),
        user_agent: String::new(),
    };
    di.rom = format!("EMUI-{}", String::from_utf8_lossy(&random_alnum(13)));
    di.rom_version = String::from_utf8_lossy(&random_alnum(2)).into_owned();
    let tt_net = "TTNetVersion:9ac8d95c 2024-11-25 QuicVersion:3f326df4 2024-11-14";
    di.user_agent = if identity.user_agent.is_empty() {
        format!(
            "com.dragon.read/{} (Linux; U; Android {}; zh_CN; {}; Build/MMB29M; Cronet/{})",
            di.manifest_version_code, di.os_version, di.device_type, tt_net
        )
    } else {
        identity
            .user_agent
            // The longer placeholder goes first: `{manifest_version_code}`
            // contains `{version_code}`, and replacing the short one first would
            // leave `{manifest_65132}` behind.
            .replace("{manifest_version_code}", &di.manifest_version_code)
            // `{version_code}` is an alias for `{manifest_version_code}`: the
            // user agent has always carried the manifest code, and after the
            // consistency rule in `UpstreamIdentity::resolved` the two are the
            // same value unless the manifest code was configured explicitly.
            .replace("{version_code}", &di.manifest_version_code)
            .replace("{os_version}", &di.os_version)
            .replace("{device_type}", &di.device_type)
    };
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
                // The device is still returned, but with an empty key it can
                // decrypt nothing. The reason must reach the log: this used to
                // go to a no-op `log_line`, which made the degradation
                // invisible in `rust.log` and `logcat` alike.
                log::warn!("registerKey failed (secret_key will be empty): {e}");
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
            openudid: di.openudid,
            // The version this device was registered with. A later identity
            // change retires the device instead of handing it out.
            registered_version_code: di.version_code.clone(),
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
            .request_with_limit(
                "POST",
                &self.target(&req_url),
                &headers,
                Some(post_data),
                None,
                Some(API_BODY_LIMIT_BYTES),
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
            return Err(format!("bad response: {}", body_head(&raw)));
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
            .request_with_limit(
                "GET",
                &self.target(&req_url),
                &headers,
                None,
                None,
                Some(API_BODY_LIMIT_BYTES),
            )
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
            .request_with_limit(
                "POST",
                &self.target(&req_url),
                &[],
                Some(body_json),
                None,
                Some(API_BODY_LIMIT_BYTES),
            )
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
                .request_with_limit(
                    "POST",
                    &self.target(&req_url),
                    &headers,
                    Some(compressed.clone()),
                    None,
                    Some(API_BODY_LIMIT_BYTES),
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
                last_err = format!("HTTP {} body={}", resp.status, body_head(&resp.body));
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

/// A diagnostic prefix of a response body.
///
/// Bodies here can be up to `API_BODY_LIMIT_BYTES` (64 MiB) and the strings
/// built from them end up in `rust.log`, which rotates at 1 MiB - interpolating
/// a whole body would evict the log's history in one line. 256 bytes is enough
/// to recognise an error envelope.
fn body_head(bytes: &[u8]) -> String {
    let head = &bytes[..bytes.len().min(256)];
    String::from_utf8_lossy(head).into_owned()
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    use crate::config::UpstreamIdentity;

    /// An empty section must reproduce the constants that used to be inline,
    /// otherwise every device registered after this change looks new upstream.
    #[test]
    fn empty_identity_keeps_the_previous_constants() {
        let di = dev_info_with(&UpstreamIdentity::default());
        assert_eq!(di.version_name, "6.5.1.32");
        assert_eq!(di.version_code, "65132");
        assert_eq!(di.manifest_version_code, "65132");
        assert_eq!(di.update_version_code, "65132");
        assert!(
            di.user_agent.starts_with(
                "com.dragon.read/65132 (Linux; U; Android 10; zh_CN; MI 12; Build/MMB29M; Cronet/"
            ),
            "got {}",
            di.user_agent
        );
    }

    #[test]
    fn configured_parameters_reach_every_version_field() {
        let identity = UpstreamIdentity {
            version_name: "7.1.3.32".into(),
            version_code: "71332".into(),
            manifest_version_code: "71332".into(),
            update_version_code: "71332".into(),
            user_agent: String::new(),
        };
        let di = dev_info_with(&identity);
        assert_eq!(di.version_name, "7.1.3.32");
        assert_eq!(di.version_code, "71332");
        assert!(
            di.user_agent.starts_with("com.dragon.read/71332 "),
            "got {}",
            di.user_agent
        );
    }

    #[test]
    fn a_ua_override_substitutes_placeholders_and_keeps_other_defaults() {
        let identity = UpstreamIdentity {
            user_agent:
                "com.phoenix.read/{version_code} (Linux; U; Android {os_version}; {device_type})"
                    .into(),
            ..UpstreamIdentity::default()
        };
        let di = dev_info_with(&identity);
        assert_eq!(
            di.user_agent,
            "com.phoenix.read/65132 (Linux; U; Android 10; MI 12)"
        );
        assert_eq!(
            di.version_name, "6.5.1.32",
            "the other fields still fall back"
        );
    }

    /// `{version_code}` is a suffix of `{manifest_version_code}`: substituting
    /// the short one first would leave `{manifest_900}` in the header.
    ///
    /// `{version_code}` is an alias for `{manifest_version_code}`, so both
    /// placeholders carry the manifest code. The two codes only differ when
    /// the manifest code was configured explicitly, which is what this case
    /// does.
    #[test]
    fn the_long_placeholder_survives_the_short_alias() {
        let identity = UpstreamIdentity {
            user_agent: "ua/{version_code}|{manifest_version_code}|{os_version}|{device_type}"
                .into(),
            version_code: "900".into(),
            manifest_version_code: "800".into(),
            ..UpstreamIdentity::default()
        };
        let di = dev_info_with(&identity);
        assert_eq!(di.user_agent, "ua/800|800|10|MI 12");
    }

    /// Configuring one version code moves the whole release: the registration
    /// header must not carry a new code next to the old manifest code.
    #[test]
    fn a_configured_version_code_moves_every_code() {
        let identity = UpstreamIdentity {
            version_code: "71332".into(),
            ..UpstreamIdentity::default()
        };
        let di = dev_info_with(&identity);
        assert_eq!(di.version_code, "71332");
        assert_eq!(di.manifest_version_code, "71332");
        assert_eq!(di.update_version_code, "71332");
        assert!(
            di.user_agent.starts_with("com.dragon.read/71332 "),
            "got {}",
            di.user_agent
        );
    }

    /// A stop/start pair in one process (`restartForListenMode`) reloads the
    /// config, so the second publication must win. A `OnceLock` kept the first one
    /// silently. This drives a local cell rather than the process-wide one: the
    /// `api::tests` init cores concurrently, and touching the global here would
    /// make this case race them for no benefit.
    #[test]
    fn the_identity_can_be_republished_for_a_restart() {
        let cell = IdentityCell::new();
        assert_eq!(
            cell.current().version_name,
            "6.5.1.32",
            "an unset cell reads as the defaults"
        );

        cell.publish(UpstreamIdentity {
            version_name: "1.0.0".into(),
            ..UpstreamIdentity::default()
        });
        assert_eq!(cell.current().version_name, "1.0.0");

        cell.publish(UpstreamIdentity {
            version_name: "2.0.0".into(),
            ..UpstreamIdentity::default()
        });
        assert_eq!(cell.current().version_name, "2.0.0");
    }
}
