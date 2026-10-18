//! Bounded, read-only account capture. Preserve original response JSON before
//! interpreting shelf membership, chapter order, or progress in the UI.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::dispatch::{Request, Response};
use crate::endpoints::Ctx;
use crate::sign::Manager;
use crate::upstream::http::HttpTransport;

const RESPONSE_LIMIT: usize = 8 * 1024 * 1024;
const ORIGIN: &str = "https://api5-normal-sinfonlineb.fqnovel.com";

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum Resource {
    History,
    ShelfList,
    ShelfInfo,
    ProgressList,
    ProgressBatch,
    FolderList,
    FolderDetail,
    Topping,
    Tabs,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CaptureRequest {
    cookie: String,
    device_id: Option<String>,
    resource: Resource,
    #[serde(default)]
    offset: u32,
    #[serde(default)]
    book_type: u32,
    #[serde(default)]
    book_ids: Vec<String>,
    folder_id: Option<String>,
}

fn response(status: u16, payload: Value) -> Response {
    let mut response = Response::json(status, &payload);
    response
        .headers
        .push(("cache-control".into(), "no-store".into()));
    response
}

fn failure(status: u16, message: &str) -> Response {
    response(status, json!({"success": false, "error": message}))
}

fn capture_failure(
    resource: Resource,
    device_id: &str,
    upstream_status: u16,
    message: &str,
) -> Response {
    // Keep the selected identity even when the first upstream call fails so
    // the next resource cannot silently select a different pooled device.
    response(
        200,
        json!({
            "code": 0,
            "resource": resource,
            "device_id": device_id,
            "upstream_status": upstream_status,
            "payload": null,
            "error": message,
        }),
    )
}

fn numeric_id(value: &str) -> Option<i64> {
    if value.is_empty() || value.len() > 19 || !value.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    value.parse::<i64>().ok().filter(|id| *id > 0)
}

pub async fn handle(ctx: &Ctx, req: &Request) -> Response {
    if req.method != "POST" {
        let mut response = failure(405, "请使用 POST 采集书架数据");
        response.headers.push(("allow".into(), "POST".into()));
        return response;
    }
    if req.body.len() > 16 * 1024 || !req.query.is_empty() {
        return failure(400, "书架采集参数无效或过长");
    }
    let input: CaptureRequest = match serde_json::from_slice(&req.body) {
        Ok(input) => input,
        Err(_) => return failure(400, "书架采集参数无效"),
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
    {
        return failure(400, "未取得有效登录态，请重新在官方页面登录");
    }
    if input.offset > 100_000
        || !matches!(input.book_type, 0..=6 | 35)
        || input.book_ids.len() > 50
        || input.book_ids.iter().any(|id| numeric_id(id).is_none())
        || input
            .folder_id
            .as_deref()
            .is_some_and(|id| numeric_id(id).is_none())
        || input
            .device_id
            .as_deref()
            .is_some_and(|id| numeric_id(id).is_none())
        || (matches!(input.resource, Resource::ProgressBatch) && input.book_ids.is_empty())
        || (matches!(input.resource, Resource::FolderDetail) && input.folder_id.is_none())
    {
        return failure(400, "书架采集参数超出允许范围");
    }
    // An account capture retains one identity. Failure never silently rotates
    // a caller-pinned device, and cookie-bearing requests do not enter retries.
    let device = match input.device_id.as_deref() {
        Some(id) => ctx.pool.get_by_id(id).await,
        None => ctx.pool.get().await,
    };
    let device = match device {
        Ok(device) => device,
        Err(_) => return failure(503, "采集所需设备不可用，请重新开始采集"),
    };
    // Paths and methods come exclusively from the inspected official RPCs.
    // No caller-provided URL, path, method, or upstream headers are accepted.
    let (method, path) = match input.resource {
        Resource::History => ("GET", "/reading/bookapi/read_history/list/v1/"),
        Resource::ShelfList => ("GET", "/reading/bookapi/bookshelf/list/v1/"),
        Resource::ShelfInfo => ("GET", "/reading/bookapi/bookshelf/info/v1/"),
        Resource::ProgressList => ("GET", "/reading/bookapi/read_progress/list/v1/"),
        Resource::ProgressBatch => ("POST", "/reading/bookapi/read_progress/get/v1/"),
        Resource::FolderList => ("POST", "/reading/distribution/bookshelf_folder/list/v1/"),
        Resource::FolderDetail => ("POST", "/reading/distribution/bookshelf_folder/detail/v1/"),
        Resource::Topping => ("GET", "/reading/bookapi/bookshelf/topping/get/v1/"),
        Resource::Tabs => ("GET", "/reading/bookapi/bookshelf/tab/v1/"),
    };
    let mut url = match reqwest::Url::parse(&format!("{ORIGIN}{path}")) {
        Ok(url) => url,
        Err(_) => return failure(500, "书架采集接口配置无效"),
    };
    url.query_pairs_mut().extend_pairs([
        ("aid", "1967"),
        ("app_name", "novelapp"),
        ("device_platform", "android"),
        ("version_code", "73932"),
        ("version_name", "7.3.9.32"),
        ("device_id", device.device_id.as_str()),
        ("iid", device.install_id.as_str()),
    ]);
    let mut body = None;
    match input.resource {
        Resource::History => {
            url.query_pairs_mut().extend_pairs([
                ("book_type", input.book_type.to_string()),
                ("limit", "0".into()),
                ("offset", input.offset.to_string()),
                ("last_min_read_timestamp_ms", "0".into()),
                ("full_field", "true".into()),
                ("is_first_load", "true".into()),
                ("query_soft_deleted", "false".into()),
            ]);
        }
        Resource::ShelfList => {
            url.query_pairs_mut().append_pair("server_time", "0");
        }
        Resource::ProgressList => {
            // Single first page only. Do not claim completeness until each
            // content type's progress timestamp/pagination semantics are known.
            // Match the request model's absent optional type/timestamp fields;
            // use explicit per-type book IDs for complete batch enrichment.
            url.query_pairs_mut().append_pair("limit", "0");
        }
        Resource::ProgressBatch => {
            let ids: Vec<i64> = input
                .book_ids
                .iter()
                .filter_map(|id| numeric_id(id))
                .collect();
            let mut types = serde_json::Map::new();
            types.insert(input.book_type.to_string(), json!(ids));
            body = Some(json!({"book_ids": types}));
        }
        Resource::FolderList => {
            body = Some(json!({
                "offset": input.offset, "count": 50, "preview_items_limit": 50,
                "target_id": "", "has_detail": true
            }));
        }
        Resource::FolderDetail => {
            body = Some(json!({
                "folder_id": input.folder_id.as_deref().and_then(numeric_id),
                "offset": input.offset, "limit": 50, "target_id": "", "has_detail": true
            }));
        }
        Resource::Topping => {
            url.query_pairs_mut().append_pair("min_data_version", "0");
        }
        Resource::Tabs => {
            url.query_pairs_mut().append_pair("session_data", "");
        }
        Resource::ShelfInfo => {}
    }
    let body = match body.map(|value| serde_json::to_vec(&value)).transpose() {
        Ok(body) => body,
        Err(_) => return failure(500, "无法构造书架采集请求"),
    };
    let client = match HttpTransport::without_redirects(20) {
        Ok(client) => client,
        Err(_) => return failure(503, "无法初始化书架采集连接"),
    };
    let mut headers = Manager::new().generate_headers(url.query().unwrap_or(""), body.as_deref());
    headers.push(("Cookie".into(), cookie.to_owned()));
    headers.push((
        "User-Agent".into(),
        crate::upstream::client::DEFAULT_USER_AGENT.into(),
    ));
    if body.is_some() {
        headers.push((
            "Content-Type".into(),
            "application/json; charset=utf-8".into(),
        ));
    }
    let upstream = match body {
        Some(body) => {
            client
                .request_body_bounded(method, url.as_str(), &headers, body, RESPONSE_LIMIT)
                .await
        }
        None => {
            client
                .request_bounded(method, url.as_str(), &headers, RESPONSE_LIMIT)
                .await
        }
    };
    let upstream = match upstream {
        Ok(upstream) => upstream,
        Err(_) => {
            return capture_failure(
                input.resource,
                &device.device_id,
                0,
                "无法读取番茄书架数据，请稍后重试",
            );
        }
    };
    // Preserve error JSON too: the archive must distinguish rejected,
    // unsupported, and empty resources without exposing response headers.
    let payload: Value = match serde_json::from_slice(&upstream.body) {
        Ok(payload) => payload,
        Err(_) => {
            return capture_failure(
                input.resource,
                &device.device_id,
                upstream.status,
                "番茄书架响应不是受支持的 JSON 数据",
            );
        }
    };
    response(
        200,
        json!({
            "code": 0,
            "resource": input.resource,
            "device_id": device.device_id,
            "upstream_status": upstream.status,
            "payload": payload,
        }),
    )
}
