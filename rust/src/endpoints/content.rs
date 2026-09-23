//! `content` endpoint. Port of `/internal/endpoints/content.go`.

use futures::future::BoxFuture;
use serde_json::{Map, Value};

use crate::endpoints::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::dhcontent::fetch_novel_reader_content;
use crate::endpoints::full::get_chapters;
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

const CONTENT_FULL_URL: &str = "https://reading.snssdk.com/reading/reader/full/v/";
const CONTENT_BATCH_URL: &str =
    "https://api5-normal-sinfonlineb.fqnovel.com/reading/reader/batch_full/v";

fn build_content_url(item_id: &str, api_type: &str) -> String {
    if api_type == "full" {
        format!(
            "{CONTENT_FULL_URL}?aid=1967&app_name=novelapp&channel=0&device_platform=android&device_id={{device_id}}&device_type=Honor10&item_id={item_id}&os_version=0&version_code=66.9"
        )
    } else {
        format!(
            "{CONTENT_BATCH_URL}?aid=1967&app_name=novelapp&channel=0&device_platform=android&device_id={{device_id}}&device_type=Honor10&os_version=0&version_code=66.9&book_id=0&item_ids={item_id}&novel_text_type=1&req_type=1"
        )
    }
}

async fn handle_single(
    ctx: &Ctx,
    item_id: &str,
    api_type: &str,
    book_id_hint: &str,
) -> ApiResult<Value> {
    let up = Upstream::new(ctx.up.clone());
    let (raw, dev) = up
        .raw_with_device(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(build_content_url(item_id, api_type)),
            headers: dragon_read_headers(),
            ..Default::default()
        })
        .await?;

    let payload: Value = serde_json::from_slice(&raw)
        .map_err(|e| ApiError::Internal(format!("parse upstream json: {e}")))?;
    let content = payload
        .get("data")
        .and_then(|d| d.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();
    if content.is_empty() {
        return crate::endpoints::util::raw_json(&raw);
    }

    match crate::crypto::decrypt_upstream(&content, &dev.secret_key) {
        Ok(plain) => {
            let text = String::from_utf8_lossy(&plain).into_owned();
            crate::endpoints::util::set_content_in_place(&raw, &text)
        }
        Err(err) => {
            let mut book_id = book_id_hint.to_string();
            if book_id.is_empty() {
                book_id = payload
                    .get("data")
                    .and_then(|d| d.get("novel_data"))
                    .and_then(|n| n.get("book_id"))
                    .and_then(|b| b.as_str())
                    .unwrap_or("")
                    .to_string();
            }
            match fallback_single_from_full(ctx, &raw, item_id, &book_id).await {
                Ok(v) => Ok(v),
                Err(_) => Err(ApiError::Internal(format!("decrypt content: {err}"))),
            }
        }
    }
}

async fn fallback_single_from_full(
    ctx: &Ctx,
    raw: &[u8],
    item_id: &str,
    book_id: &str,
) -> ApiResult<Value> {
    if book_id.is_empty() {
        return Err(ApiError::Internal(
            "missing book_id for full fallback".to_string(),
        ));
    }
    let full_resp = get_chapters(ctx, book_id, &[item_id.to_string()]).await?;
    let (content, title, ok) = full_item_content(&full_resp, item_id);
    if !ok {
        return Err(ApiError::Internal(
            "full fallback content missing".to_string(),
        ));
    }
    let content = if !title.is_empty() && !content.contains(&title) {
        format!("{title}\n{content}")
    } else {
        content
    };
    crate::endpoints::util::set_content_in_place(raw, &content)
}

/// `fullItemContent`.
pub fn full_item_content(v: &Value, item_id: &str) -> (String, String, bool) {
    let item = match v
        .get("data")
        .and_then(|d| d.get("item_infos"))
        .and_then(|i| i.get(item_id))
    {
        Some(i) => i,
        None => return (String::new(), String::new(), false),
    };
    let content = item
        .get("content")
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();
    let title = item
        .get("title")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .to_string();
    let ok = !content.trim().is_empty();
    (content, title, ok)
}

async fn handle_batch(ctx: &Ctx, item_ids: &str) -> ApiResult<Value> {
    let up = Upstream::new(ctx.up.clone());
    let (raw, dev) = up
        .raw_with_device(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(build_content_url(item_ids, "batch")),
            headers: dragon_read_headers(),
            ..Default::default()
        })
        .await?;

    let mut root: Value = serde_json::from_slice(&raw)
        .map_err(|e| ApiError::Internal(format!("parse upstream json: {e}")))?;
    let data_map = match root.get("data").and_then(|d| d.as_object()) {
        Some(d) if !d.is_empty() => d.clone(),
        _ => return crate::endpoints::util::raw_json(&raw),
    };

    let mut out: Map<String, Value> = Map::new();
    for (id, item) in data_map {
        match item {
            Value::Object(mut m) => {
                let enc = m
                    .get("content")
                    .and_then(|c| c.as_str())
                    .unwrap_or("")
                    .to_string();
                if !enc.is_empty() {
                    if let Ok(plain) = crate::crypto::decrypt_upstream(&enc, &dev.secret_key) {
                        m.insert(
                            "content".to_string(),
                            Value::from(String::from_utf8_lossy(&plain).into_owned()),
                        );
                    }
                }
                out.insert(id, Value::Object(m));
            }
            other => {
                out.insert(id, other);
            }
        }
    }
    if let Some(root_obj) = root.as_object_mut() {
        root_obj.insert("data".to_string(), Value::Object(out));
    }
    Ok(root)
}

fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_ids = params.get_str("item_ids");
        if item_ids.is_empty() {
            return Err(ApiError::BadRequest(
                "missing item_ids parameter".to_string(),
            ));
        }
        let api_type = crate::endpoints::util::default_val(&params.get_str("api_type"), "full");

        let batch = item_ids.contains(',') || api_type == "batch";
        if batch {
            return handle_batch(ctx, &item_ids).await;
        }
        if api_type == "novel" {
            return fetch_novel_reader_content(ctx, &item_ids).await;
        }
        handle_single(ctx, &item_ids, &api_type, &params.get_str("book_id")).await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("content", handle);
}
