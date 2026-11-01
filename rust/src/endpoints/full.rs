//! `full` endpoint: CM DH handshake + per-item AES-256 decrypt.

use std::sync::Arc;

use futures::future::BoxFuture;
use futures::{stream, StreamExt};
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
    let cm = Arc::new(
        CM::new_off_thread()
            .await
            .map_err(|e| ApiError::Internal(format!("cm init: {e}")))?,
    );
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
    drop(raw);
    // Inspect before mutating so the pass-through cases return the parsed root
    // untouched. The checks borrow immutably; the clone-free take below needs
    // the borrow to end first.
    if !matches!(
        root.get("data").and_then(|d| d.as_object()),
        Some(d) if !d.is_empty()
    ) {
        return Ok(root);
    }
    if root.get("data").and_then(|d| d.get("item_infos")).is_none() {
        return Ok(root);
    }
    // Take `item_infos` out of `data` in place: cloning the whole map (and
    // then inserting the processed one back) copied every chapter body for no
    // reason. `mem::take` leaves the key in place, so key order and therefore
    // the serialized JSON stay unchanged.
    let data = root
        .as_object_mut()
        .and_then(|root_obj| root_obj.get_mut("data"))
        .and_then(|d| d.as_object_mut())
        .expect("data is a non-empty object, checked above");
    let item_infos = data
        .get_mut("item_infos")
        .map(std::mem::take)
        .expect("item_infos exists, checked above");

    let processor = FullContentProcessor::new();
    let zwsm = ctx.cfg.zwsm.clone();

    match item_infos {
        Value::Object(item_map) => {
            let mut out = Map::new();
            let mut pending = stream::iter(item_map)
                .map(|(id, item)| {
                    let cm = &cm;
                    let zwsm = &zwsm;
                    let processor = &processor;
                    async move {
                        let item = match item {
                            Value::Object(mut obj) => {
                                decrypt_full_item_content(&id, &mut obj, cm, zwsm, processor).await;
                                Value::Object(obj)
                            }
                            other => other,
                        };
                        (id, item)
                    }
                })
                .buffer_unordered(2);
            while let Some((id, item)) = pending.next().await {
                out.insert(id, item);
            }
            data.insert("item_infos".to_string(), Value::Object(out));
        }
        Value::Array(item_arr) => {
            // Arrays preserve upstream order; CM also enforces a process-wide
            // limit so concurrent batches cannot flood the blocking pool.
            let out = stream::iter(item_arr)
                .map(|item| {
                    let cm = &cm;
                    let zwsm = &zwsm;
                    let processor = &processor;
                    async move {
                        match item {
                            Value::Object(mut obj) => {
                                decrypt_full_item_content("", &mut obj, cm, zwsm, processor).await;
                                Value::Object(obj)
                            }
                            other => other,
                        }
                    }
                })
                .buffered(2)
                .collect()
                .await;
            data.insert("item_infos".to_string(), Value::Array(out));
        }
        other => {
            data.insert("item_infos".to_string(), other);
        }
    }

    Ok(root)
}

async fn decrypt_full_item_content(
    label: &str,
    item_obj: &mut Map<String, Value>,
    cm: &Arc<CM>,
    zwsm: &str,
    processor: &FullContentProcessor,
) {
    let key = item_obj
        .get("key")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let Some(Value::String(content)) = item_obj.get_mut("content") else {
        return;
    };
    if key.is_empty() || content.is_empty() {
        return;
    }
    let content = std::mem::take(content);
    let content_len = content.len();
    let key_len = key.len();
    let zwsm = zwsm.to_owned();
    let processor = *processor;
    let processed = cm
        .process_off_thread(move |cm| {
            let plain = cm.decrypt(&key, &content)?;
            let mut text = processor.process(&String::from_utf8_lossy(&plain));
            text.push_str(&zwsm);
            Ok(text)
        })
        .await;
    match processed {
        Ok(text) => {
            item_obj.insert("content".to_string(), Value::from(text));
        }
        Err(error) => {
            // A failed decrypt is not "no content": leaving the upstream base64
            // in place means it gets served as the chapter text, because
            // `content.rs` only checks that `content` is non-empty. Drop the
            // field so the caller's fallback can take over, and say so - this
            // used to fail with no log at all.
            log::warn!(
                "full content {label}: decrypt failed ({error}); dropping ciphertext \
                 (content_len={}, key_len={})",
                content_len,
                key_len
            );
            item_obj.remove("content");
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A failed decrypt must not leave the upstream base64 in place: `content.rs`
    /// only checks that `content` is non-empty, so it used to be served as the
    /// chapter text. Dropping the field lets the caller's fallback take over.
    #[tokio::test]
    async fn a_failed_decrypt_drops_the_ciphertext_instead_of_serving_it() {
        let cm = Arc::new(CM::new().expect("cm"));
        let mut item = Map::new();
        // Short content / degenerate key: `CM::decrypt` returns an error for both.
        item.insert("key".to_string(), Value::from("AQ=="));
        item.insert("content".to_string(), Value::from("AAAA"));

        decrypt_full_item_content(
            "chapter-1",
            &mut item,
            &cm,
            "",
            &FullContentProcessor::new(),
        )
        .await;

        assert!(
            !item.contains_key("content"),
            "failed ciphertext must not survive as the chapter body: {item:?}"
        );
    }
}
