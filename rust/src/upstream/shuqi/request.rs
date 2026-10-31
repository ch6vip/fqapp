//! 加密口请求体与固定头。

use super::crypto::{enc18, now_ms, public_str, sign, uri_encode, xor_base64, SKEY, SQ_SV};
use super::params::{device, Device, PUB_PARAMS};

/// 请求体末尾携带的网关标识。
const GATEWAY_KEY: &str = "sq_app_gateway";
/// `x-sq-s-key` 头。
const SG_APP_KEY: &str = "23011413";
/// `x-sq-sv` 头。
const SV: &str = "3.0";

/// 一个可直接交给上游层的加密口请求。
pub struct AppRequest {
    pub body: String,
    pub headers: Vec<(String, String)>,
}

fn put(items: &mut Vec<(String, String)>, key: &str, value: String) {
    if let Some(slot) = items.iter_mut().find(|(k, _)| k == key) {
        slot.1 = value;
    } else {
        items.push((key.to_string(), value));
    }
}

/// 构造加密口请求体与 9 个固定头。
///
/// `biz` 是业务参数；`uid` 缺省走 [`APP_USER_ID`](super::APP_USER_ID)；`ts` 缺省取当前毫秒。
pub fn app_body(
    biz: &[(&str, &str)],
    uid: Option<&str>,
    ts: Option<&str>,
) -> Result<AppRequest, String> {
    app_body_with_device(biz, uid, ts, device())
}

/// [`app_body`] 的可注入设备版本：设备身份固定，结果可复现（向量比对与测试用）。
pub fn app_body_with_device(
    biz: &[(&str, &str)],
    uid: Option<&str>,
    ts: Option<&str>,
    dev: &Device,
) -> Result<AppRequest, String> {
    let uid = uid.unwrap_or(super::APP_USER_ID);
    let ts = ts.map(str::to_string).unwrap_or_else(now_ms);
    let enc = enc18(uid, &ts);

    let mut p: Vec<(String, String)> = PUB_PARAMS
        .iter()
        .map(|(k, v)| (k.to_string(), (*v).to_string()))
        .collect();
    for (k, v) in dev.pairs() {
        put(&mut p, k, v);
    }
    put(&mut p, "user_id", uid.to_string());
    put(&mut p, "userId", uid.to_string());
    put(&mut p, "platform", "an".to_string());
    put(&mut p, "enc", enc.clone());
    put(&mut p, "timestamp", ts.clone());
    for (k, v) in biz {
        put(&mut p, k, (*v).to_string());
    }
    put(&mut p, "isTeenMode", "0".to_string());
    put(&mut p, "sqSv", SQ_SV.to_string());
    let sig = sign(&p, SKEY);
    put(&mut p, "sign", sig);
    // key 只随 JSON 发出，不参与签名。
    put(&mut p, "key", GATEWAY_KEY.to_string());

    let mut obj = serde_json::Map::new();
    for (k, v) in &p {
        obj.insert(k.clone(), serde_json::Value::String(v.clone()));
    }
    let json = serde_json::to_vec(&serde_json::Value::Object(obj)).map_err(|e| e.to_string())?;
    let cipher = xor_base64(&json)?;

    let public = public_str(uid, &ts, &enc, dev);
    let public_cipher = xor_base64(public.as_bytes())?;

    Ok(AppRequest {
        body: format!("data={}", uri_encode(&cipher)),
        headers: vec![
            (
                "content-type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            ),
            ("user-agent".to_string(), super::UA.to_string()),
            ("x-sq-req-platform".to_string(), "an".to_string()),
            ("x-sq-s-key".to_string(), SG_APP_KEY.to_string()),
            ("x-sq-sv".to_string(), SV.to_string()),
            ("x-sq-public".to_string(), public_cipher),
            ("x-sq-req-encrypt".to_string(), "sdk".to_string()),
            (
                "x-sq-req-encrypt-param".to_string(),
                "x-sq-public".to_string(),
            ),
            ("x-sq-api-encrypt".to_string(), "1".to_string()),
        ],
    })
}
