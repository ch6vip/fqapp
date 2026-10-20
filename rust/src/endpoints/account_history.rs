//! Experimental, read-only account history adapter. Static protocol evidence:
//! official com.dragon.read 7.3.9.32, GetReadHistoryRequest/Response.
//! Website-session compatibility still requires a real user login acceptance.

use serde::Deserialize;
use serde_json::{json, Value};

use crate::dispatch::{Request, Response};
use crate::endpoints::Ctx;
use crate::sign::Manager;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HistoryRequest {
    cookie: String,
    offset: u32,
    last_min_read_timestamp_ms: u64,
    is_first_load: bool,
    device_id: Option<String>,
}

fn failure(status: u16, message: &str) -> Response {
    let mut response = Response::json(status, &json!({"success": false, "error": message}));
    response
        .headers
        .push(("cache-control".into(), "no-store".into()));
    response
}

pub async fn handle(ctx: &Ctx, req: &Request) -> Response {
    if req.method != "POST" {
        let mut response = failure(405, "请使用 POST 读取历史");
        response.headers.push(("allow".into(), "POST".into()));
        return response;
    }
    // The FFI path needs its own limit as well as the HTTP adapter's limit.
    if req.body.len() > 16 * 1024 || !req.query.is_empty() {
        return failure(400, "历史读取参数无效或过长");
    }
    let input: HistoryRequest = match serde_json::from_slice(&req.body) {
        Ok(input) => input,
        Err(_) => return failure(400, "历史读取参数无效"),
    };
    let cookie = input.cookie.trim();
    let has_session = cookie.split(';').any(|part| {
        part.trim().split_once('=').is_some_and(|(key, value)| {
            matches!(key, "sessionid" | "sessionid_ss" | "sid_tt") && !value.is_empty()
        })
    });
    if cookie.is_empty()
        || cookie.len() > 12 * 1024
        || !cookie.bytes().all(|b| (0x20..=0x7e).contains(&b))
        || !has_session
        || input.offset > 100_000
        || input.last_min_read_timestamp_ms > 8_640_000_000_000_000
    {
        return failure(400, "未取得有效登录态，请重新在官方页面登录");
    }
    // A failed pinned device is surfaced, never replaced under an account.
    let device = match input.device_id {
        Some(id) if !id.is_empty() => ctx.pool.get_by_id(&id).await,
        _ => ctx.pool.get().await,
    };
    let device = match device {
        Ok(device) => device,
        Err(_) => return failure(503, "读取历史所需设备不可用，请重新开始导入"),
    };
    let mut url = match reqwest::Url::parse(
        "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/read_history/list/v1/",
    ) {
        Ok(url) => url,
        Err(_) => return failure(500, "历史接口配置无效"),
    };
    url.query_pairs_mut().extend_pairs([
        ("aid", "1967"),
        ("app_name", "novelapp"),
        ("device_platform", "android"),
        ("version_code", "73932"),
        ("version_name", "7.3.9.32"),
        ("device_id", device.device_id.as_str()),
        ("iid", device.install_id.as_str()),
        ("book_type", "0"),
        // nh4.n in the inspected APK uses the request defaults and offset.
        ("limit", "0"),
        ("offset", &input.offset.to_string()),
        ("last_min_read_timestamp_ms", "0"),
        ("full_field", "false"),
        (
            "is_first_load",
            if input.is_first_load { "true" } else { "false" },
        ),
        ("query_soft_deleted", "false"),
    ]);
    // Separate client: never forward an account cookie across a redirect and
    // never persist cookies or retry against other identities.
    let client = match crate::upstream::http::HttpTransport::without_redirects(20) {
        Ok(client) => client,
        Err(_) => return failure(503, "无法初始化历史读取连接"),
    };
    let mut headers = Manager::new().generate_headers(url.query().unwrap_or(""), None);
    headers.push(("Cookie".into(), cookie.to_owned()));
    headers.push((
        "User-Agent".into(),
        crate::upstream::client::DEFAULT_USER_AGENT.into(),
    ));
    let upstream = match client
        .request_bounded("GET", url.as_str(), &headers, 8 * 1024 * 1024)
        .await
    {
        Ok(response) => response,
        Err(_) => return failure(502, "无法连接番茄历史接口，请稍后重试"),
    };
    if upstream.status != 200 {
        return failure(502, "番茄未接受历史读取请求，网页登录态可能不兼容 App 接口");
    }
    if upstream.body.len() > 8 * 1024 * 1024 {
        return failure(502, "番茄历史响应过大，已停止读取");
    }
    let mut payload: Value = match serde_json::from_slice(&upstream.body) {
        Ok(Value::Object(payload)) => Value::Object(payload),
        _ => return failure(502, "番茄历史响应格式不受支持"),
    };
    if payload.get("code").and_then(Value::as_i64) != Some(0) {
        return failure(
            401,
            "读取历史未获授权，请重新登录；网页账号可能无法读取 App 历史",
        );
    }
    if !payload
        .pointer("/data/data_list")
        .is_some_and(Value::is_array)
    {
        return failure(502, "响应未包含历史列表，未将其当作空历史导入");
    }
    payload["_fqapp_device_id"] = Value::String(device.device_id);
    let mut response = Response::json(200, &payload);
    response
        .headers
        .push(("cache-control".into(), "no-store".into()));
    response
}
