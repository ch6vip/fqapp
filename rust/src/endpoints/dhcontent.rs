//! DH-encrypted novel reader content, shared by the `content` (api_type=novel)
//! and `toutiao` endpoints.

use serde_json::Value;

use crate::endpoints::base::{Upstream, UpstreamMode, UpstreamRequestSpec, HOST_NOVEL_SNSSDK};
use crate::endpoints::Ctx;
use crate::error::{ApiError, ApiResult};
use crate::upstream::dh::{decrypt_dh_content, generate_y, DHState};

/// `novelReaderContentURL`.
pub fn novel_reader_content_url(item_id: &str) -> String {
    format!(
        "{HOST_NOVEL_SNSSDK}/api/novel/book/reader/content/v1?aid=13&app_name=novelapp&channel=0&device_platform=android&device_type=25053RT47C&item_id={}&os_version=10&support_image=1&version_code=66.9",
        crate::endpoints::util::go_query_escape(item_id)
    )
}

/// `novelReaderContentHeaders`.
pub fn novel_reader_content_headers(y: &str) -> Vec<(String, String)> {
    vec![
        (
            "User-Agent".to_string(),
            "com.ss.android.article.news/13400 (Linux; U; Android 10; zh_CN; tb8788p1_64_bsp; Build/QQ3A.200805.001; Cronet/TTNetVersion:fc4cebd3 2024-12-10 QuicVersion:d9628e3d 2024-10-11)".to_string(),
        ),
        ("Accept-Encoding".to_string(), "gzip, deflate".to_string()),
        ("y".to_string(), y.to_string()),
    ]
}

/// `setDHContentInPlace`.
pub fn set_dh_content_in_place(
    raw: &[u8],
    resp_headers: &[(String, String)],
    state: &DHState,
) -> ApiResult<Value> {
    let header = |name: &str| -> Option<&str> {
        resp_headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    };

    let y_resp = header("y").unwrap_or("").to_string();
    let mut c_resp = header("c").unwrap_or("").to_string();

    let payload: Value = serde_json::from_slice(raw).unwrap_or(Value::Null);
    let data_content = payload
        .get("data")
        .and_then(|d| d.get("content"))
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();

    if (c_resp == "1" || c_resp.is_empty()) && !data_content.is_empty() {
        c_resp = data_content.clone();
    }
    if y_resp.is_empty() || c_resp.is_empty() {
        if header("c") == Some("1") && !data_content.is_empty() {
            return Err(ApiError::Internal(
                "novel content response is missing its decryption key".to_string(),
            ));
        }
        return crate::endpoints::util::raw_json(raw);
    }

    let plain = decrypt_dh_content(&y_resp, &c_resp, state)
        .map_err(|e| ApiError::Internal(format!("decrypt novel content: {e}")))?;
    if plain.is_empty() {
        return Err(ApiError::Internal(
            "decrypted novel content is empty or invalid UTF-8".to_string(),
        ));
    }
    let text = String::from_utf8(plain).map_err(|_| {
        ApiError::Internal("decrypted novel content is empty or invalid UTF-8".to_string())
    })?;

    let mut result = crate::endpoints::util::set_content_in_place(raw, &text)?;
    if let Some(root) = result.as_object_mut() {
        if let Some(data) = root.get_mut("data").and_then(|d| d.as_object_mut()) {
            data.insert("content_decrypted".to_string(), Value::Bool(true));
        }
    }
    Ok(result)
}

/// `fetchNovelReaderContent`: signed (not device-bound) DH content fetch.
pub async fn fetch_novel_reader_content(ctx: &Ctx, item_id: &str) -> ApiResult<Value> {
    let target_url = novel_reader_content_url(item_id);
    let (y, state) = generate_y().map_err(|e| ApiError::Internal(format!("generate dh y: {e}")))?;
    let up = Upstream::new(ctx.up.clone());
    let (raw, headers) = up
        .raw_with_headers(&UpstreamRequestSpec {
            mode: UpstreamMode::Signed,
            raw_url: Some(target_url),
            headers: novel_reader_content_headers(&y),
            ..Default::default()
        })
        .await?;
    set_dh_content_in_place(&raw, &headers, &state)
}
