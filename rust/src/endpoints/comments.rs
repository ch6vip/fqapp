//! Comments endpoints. Port of book_reviews.go, idea_list.go,
//! book_comments_legacy.go, comment_replies.go and chapter_summary.go.

use futures::future::BoxFuture;
use serde_json::{json, Value};

use crate::endpoints::base::{
    dragon_read_headers, dragon_read_json_headers, Upstream, UpstreamMode, UpstreamRequestSpec,
    HOST_FQNOVEL,
};
use crate::endpoints::util::{clean_item_ids, default_val, int_default};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

const BOOK_REVIEWS_PATH: &str = "/novel/commentapi/comment/list/";
const IDEA_LIST_PATH: &str = "/novel/commentapi/idea/list/";
const COMMENT_REPLIES_PATH: &str = "/novel/commentapi/reply/list/";
const CHAPTER_SUMMARY_PATH: &str = "/reading/reader/item_summary/mget/v";

const BOOK_COMMENTS_LEGACY_HOST: &str = "https://api3-normal-sinfonlineb.fqnovel.com";
const BOOK_COMMENTS_LEGACY_PATH: &str = "/reading/ugc/novel_comment/book/v/";

/// Go's url.PathEscape (encodePathSegment): the unreserved set plus the
/// reserved bytes 0x24 0x26 0x2B 0x3A 0x3D 0x40 (dollar, ampersand, plus,
/// colon, equals, at) are left verbatim; slash, semicolon, comma, question
/// mark and everything else (including non-ASCII bytes) are percent-encoded
/// with uppercase hex.
fn go_path_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'~'
            | 0x24
            | 0x26
            | 0x2B
            | 0x3A
            | 0x3D
            | 0x40 => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The shared reading724Params() query bag from content_util.go.
fn reading724_params() -> Vec<(String, String)> {
    vec![
        ("iid".to_string(), "{install_id}".to_string()),
        ("device_id".to_string(), "{device_id}".to_string()),
        ("ac".to_string(), "wifi".to_string()),
        ("channel".to_string(), "xiaomi_1967_64".to_string()),
        ("aid".to_string(), "1967".to_string()),
        ("app_name".to_string(), "novelapp".to_string()),
        ("version_code".to_string(), "72432".to_string()),
        ("version_name".to_string(), "7.2.4.32".to_string()),
        ("device_platform".to_string(), "android".to_string()),
        ("os".to_string(), "android".to_string()),
        ("ssmix".to_string(), "a".to_string()),
        ("device_type".to_string(), "25053RT47C".to_string()),
        ("device_brand".to_string(), "Redmi".to_string()),
        ("language".to_string(), "zh".to_string()),
        ("os_api".to_string(), "36".to_string()),
        ("os_version".to_string(), "16".to_string()),
        ("manifest_version_code".to_string(), "72432".to_string()),
        ("resolution".to_string(), "1280*2620".to_string()),
        ("dpi".to_string(), "520".to_string()),
        ("update_version_code".to_string(), "72432".to_string()),
        ("host_abi".to_string(), "arm64-v8a".to_string()),
        ("dragon_device_type".to_string(), "phone".to_string()),
        ("pv_player".to_string(), "72432".to_string()),
        ("compliance_status".to_string(), "0".to_string()),
        ("need_personal_recommend".to_string(), "1".to_string()),
        ("player_so_load".to_string(), "1".to_string()),
        ("is_android_pad_screen".to_string(), "0".to_string()),
        (
            "rom_version".to_string(),
            "miui_V816_OS3.0.9.0.WOLCNXM".to_string(),
        ),
    ]
}

/// reading724LargeScreenParams(): same bag with the large-screen resolution.
fn reading724_large_screen_params() -> Vec<(String, String)> {
    let mut params = reading724_params();
    set_param(&mut params, "resolution", "1280*2772");
    params
}

/// Go's url.Values.Set: replace every existing value for the key.
fn set_param(params: &mut Vec<(String, String)>, key: &str, value: &str) {
    params.retain(|(k, _)| k != key);
    params.push((key.to_string(), value.to_string()));
}

/// Go's splitCSV: parse a comma separated id list, dropping blanks.
fn split_csv(value: &str) -> Vec<String> {
    if value.trim().is_empty() {
        return Vec::new();
    }
    value
        .split(',')
        .map(|part| part.trim())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_string())
        .collect()
}

/// The upstream-facing parameter set for a comment list.
struct BookReviewParams {
    book_id: String,
    group_id: String,
    group_type: i64,
    comment_source: i64,
    comment_type: i64,
    server_channel: i64,
    para_index: i64,
    item_version: String,
    insert_ids: Vec<String>,
    item_count: i64,
    count: i64,
    sort: i64,
    fold_type: i64,
    cursor: String,
}

/// bookReviewBody: builds the upstream request body.
fn book_review_body(p: &BookReviewParams) -> ApiResult<Vec<u8>> {
    let mut business = json!({
        "book_id": p.book_id,
        "comment_sort_debug": false,
        "end_offset_time": 0,
        "fold_type": p.fold_type,
        "item_count": p.item_count,
        "item_version": p.item_version,
        "max_item_count": 0,
        "need_danmaku_occlusion_face_data": false,
        "para_index": p.para_index,
        "playlet_item_duration": 0,
        "read_item_count": 0,
        "req_type": 0,
        "start_offset_time": 0,
    });
    if !p.insert_ids.is_empty() {
        business["insert_comment_ids"] = json!(p.insert_ids);
    }
    business["need_count"] = json!(p.cursor.is_empty());

    let mut body = json!({
        "business_param": business,
        "comment_source": p.comment_source,
        "comment_type": p.comment_type,
        "count": p.count,
        "group_id": p.group_id,
        "group_type": p.group_type,
        "server_channel": p.server_channel,
        "sort": p.sort,
    });
    if !p.cursor.is_empty() {
        body["cursor"] = json!(p.cursor);
    }
    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))
}

/// ideaListBody: builds the upstream request body.
fn idea_list_body(item_id: &str, item_version: &str, comment_source: i64) -> ApiResult<Vec<u8>> {
    let body = json!({
        "comment_source": comment_source,
        "compliance_status": 0,
        "item_id": item_id,
        "item_version": item_version,
        "server_channel": 7,
    });
    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))
}

fn handle_book_reviews<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        // A book review is a comment on the book itself, so the container
        // defaults to the book id.
        let group_id = default_val(&params.get_str("group_id"), &book_id);
        if group_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: book_id 或 group_id 至少需要一个".to_string(),
            ));
        }

        let body = book_review_body(&BookReviewParams {
            book_id,
            group_id: group_id.clone(),
            group_type: int_default(&params.get_str("group_type"), 1),
            comment_source: int_default(&params.get_str("comment_source"), 1),
            comment_type: int_default(&params.get_str("comment_type"), 2),
            server_channel: int_default(&params.get_str("server_channel"), 7),
            para_index: int_default(&params.get_str("para_index"), 0),
            item_version: params.get_str("item_version"),
            insert_ids: split_csv(&params.get_str("insert_comment_ids")),
            item_count: int_default(&params.get_str("item_count"), 0),
            count: int_default(&params.get_str("count"), 20),
            sort: int_default(&params.get_str("sort"), 1),
            fold_type: int_default(&params.get_str("fold_type"), 1),
            cursor: params.get_str("cursor"),
        })?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: format!("{BOOK_REVIEWS_PATH}{}/v1", go_path_escape(&group_id)),
                params: reading724_params(),
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_idea_list<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_id = params.get_str("item_id");
        if item_id.is_empty() {
            return Err(ApiError::BadRequest("缺少item_id参数".to_string()));
        }

        let body = idea_list_body(
            &item_id,
            &params.get_str("item_version"),
            int_default(&params.get_str("comment_source"), 3),
        )?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: format!("{IDEA_LIST_PATH}{}/v1/", go_path_escape(&item_id)),
                params: reading724_params(),
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_book_comments_legacy<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }
        let count = default_val(&params.get_str("count"), "10");
        let offset = default_val(&params.get_str("offset"), "0");

        let query: Vec<(String, String)> = vec![
            ("app_name".to_string(), "novelapp".to_string()),
            ("channel".to_string(), "0".to_string()),
            ("book_id".to_string(), book_id),
            ("device_type".to_string(), "Honor10".to_string()),
            ("aid".to_string(), "1967".to_string()),
            ("version_name".to_string(), "5.1.5.32".to_string()),
            ("count".to_string(), count),
            ("os_version".to_string(), "9.3.5".to_string()),
            ("device_platform".to_string(), "android".to_string()),
            ("version_code".to_string(), "515".to_string()),
            ("device_id".to_string(), "{device_id}".to_string()),
            ("offset".to_string(), offset),
        ];

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: BOOK_COMMENTS_LEGACY_HOST.to_string(),
                path: BOOK_COMMENTS_LEGACY_PATH.to_string(),
                params: query,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_comment_replies<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let comment_id = params.get_str("comment_id");
        let group_id = params.get_str("group_id");
        let book_id = params.get_str("book_id");
        if comment_id.is_empty() || group_id.is_empty() || book_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: comment_id / group_id / book_id 均为必填".to_string(),
            ));
        }

        let body = json!({
            "aid": 1967,
            "business_param": {
                "book_id": book_id,
                "client_ab_params": "{\"comment_dislike_filter\":\"0\"}",
                "need_count": false,
            },
            "comment_id": comment_id,
            "comment_source": 502,
            "comment_type": 1,
            "compliance_status": 0,
            "count": int_default(&params.get_str("count"), 10),
            "cursor": "",
            "group_id": group_id,
            "group_type": 15,
        });
        let body = serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: format!("{COMMENT_REPLIES_PATH}{}/v1/", go_path_escape(&comment_id)),
                params: reading724_large_screen_params(),
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_chapter_summary<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_ids = params.get_str("item_ids");
        if item_ids.is_empty() {
            return Err(ApiError::BadRequest("缺少item_ids参数".to_string()));
        }
        // clean whitespace/stray commas
        let item_ids = clean_item_ids(&item_ids);

        // book_id is optional context in the REST route.
        let book_id = params.get_str("book_id");

        let mut query = reading724_params();
        set_param(&mut query, "item_ids", &item_ids);
        set_param(&mut query, "book_id", &book_id);

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: CHAPTER_SUMMARY_PATH.to_string(),
                params: query,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("book_reviews", handle_book_reviews);
    s.add_route("idea_list", handle_idea_list);
    s.add_route("book_comments_legacy", handle_book_comments_legacy);
    s.add_route("comment_replies", handle_comment_replies);
    s.add_route("chapter_summary", handle_chapter_summary);
}
