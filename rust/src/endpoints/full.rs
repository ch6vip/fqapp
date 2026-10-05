//! `full` endpoint: CM DH handshake + per-item AES-256 decrypt.

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::endpoints::base::{
    dragon_read_json_headers, Upstream, UpstreamMode, UpstreamRequestSpec,
};
use crate::endpoints::content_util::FullContentProcessor;
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};
use crate::upstream::cm::CM;

const FULL_MGET_URL: &str = "https://novelfm-hl.snssdk.com/novelfm/playerapi/full/mget/v1/?aid=3040&app_name=novelapp&channel=0&device_id={device_id}&device_platform=android&device_type=UGFFI55&iid={install_id}&os_version=0&version_code=58932&version_name=5.8.9.32";

/// Accepts either a JSON array ("[1,2]") or a comma list ("1,2").
pub fn parse_item_ids(raw: &str) -> Vec<String> {
    let raw = raw.trim();
    if raw.starts_with('[') {
        if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(raw) {
            return arr
                .iter()
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    Value::Number(n) => n.to_string(),
                    other => other.to_string(),
                })
                .collect();
        }
    }
    raw.split(',')
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .map(|p| p.to_string())
        .collect()
}

pub async fn get_chapters(ctx: &Ctx, book_id: &str, item_ids: &[String]) -> ApiResult<Value> {
    let cm = CM::new().map_err(|e| ApiError::Internal(format!("cm init: {e}")))?;
    let key = cm.client_handshake();

    let req_body = serde_json::to_vec(&json!({
        "book_id": book_id,
        "item_ids": item_ids,
        "key": key,
    }))
    .map_err(|e| ApiError::Internal(e.to_string()))?;

    let up = Upstream::new(ctx.up.clone());
    let raw = up
        .raw(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(FULL_MGET_URL.to_string()),
            body: Some(req_body),
            headers: dragon_read_json_headers(),
            ..Default::default()
        })
        .await?;

    let mut root: Value = crate::endpoints::util::raw_json(&raw)?;
    let mut data: Map<String, Value> = match root.get("data").and_then(|d| d.as_object()) {
        Some(d) if !d.is_empty() => d.clone(),
        _ => return Ok(root),
    };
    let item_infos = match data.get("item_infos") {
        Some(v) => v.clone(),
        None => return Ok(root),
    };

    let processor = FullContentProcessor::new();
    let zwsm = ctx.cfg.zwsm.clone();

    match item_infos {
        Value::Object(item_map) => {
            let mut out = Map::new();
            for (id, item) in item_map {
                match item {
                    Value::Object(mut obj) => {
                        decrypt_full_item_content(&mut obj, &cm, &zwsm, &processor);
                        out.insert(id, Value::Object(obj));
                    }
                    other => {
                        out.insert(id, other);
                    }
                }
            }
            data.insert("item_infos".to_string(), Value::Object(out));
        }
        Value::Array(item_arr) => {
            let mut out = Vec::with_capacity(item_arr.len());
            for item in item_arr {
                match item {
                    Value::Object(mut obj) => {
                        decrypt_full_item_content(&mut obj, &cm, &zwsm, &processor);
                        out.push(Value::Object(obj));
                    }
                    other => out.push(other),
                }
            }
            data.insert("item_infos".to_string(), Value::Array(out));
        }
        other => {
            data.insert("item_infos".to_string(), other);
        }
    }

    if let Some(root_obj) = root.as_object_mut() {
        root_obj.insert("data".to_string(), Value::Object(data));
    }
    Ok(root)
}

fn decrypt_full_item_content(
    item_obj: &mut Map<String, Value>,
    cm: &CM,
    zwsm: &str,
    processor: &FullContentProcessor,
) {
    let key = item_obj
        .get("key")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let content = item_obj
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if key.is_empty() || content.is_empty() {
        return;
    }
    if let Ok(plain) = cm.decrypt(&key, &content) {
        let text = format!(
            "{}{}",
            processor.process(&String::from_utf8_lossy(&plain)),
            zwsm
        );
        item_obj.insert("content".to_string(), Value::from(text));
    }
}

fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少必要参数: book_id".to_string()));
        }
        let item_ids_raw = params.get_str("item_ids");
        if item_ids_raw.is_empty() {
            return Err(ApiError::BadRequest("缺少必要参数: item_ids".to_string()));
        }
        let item_ids = parse_item_ids(&item_ids_raw);
        if item_ids.is_empty() {
            return Err(ApiError::BadRequest("item_ids参数不能为空".to_string()));
        }
        if item_ids.len() > 3000 {
            return Err(ApiError::BadRequest(
                "单次请求章节数量不能超过3000个".to_string(),
            ));
        }
        get_chapters(ctx, &book_id, &item_ids).await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("full", handle);
}
