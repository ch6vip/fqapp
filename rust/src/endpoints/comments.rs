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
const COMMENT_ADD_PATH: &str = "/novel/commentapi/comment/add/v1/";
const COMMENT_REPLY_ADD_PATH: &str = "/novel/commentapi/reply/add/v1/";
/// 官方评论点赞（`UgcApiService.java:443`）。
const COMMENT_DIGG_PATH: &str = "/reading/ugc/novel_comment/digg/v";

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

/// The official playlet (short-drama) comment parameter set.
///
/// Values come from the official client's `gx1.m` constructor
/// (J:gx1/m.java:168-181) and the enums it reads:
/// `UgcCommentSourceEnum.NovelBookComment=1`,
/// `UgcCommentChannelEnum.NovelPlayletCommentInnerList=34`,
/// `UgcRelativeType.Book=1`, `UgcCommentGroupTypeOutter.Book=2`,
/// `UgcSortEnum.SmartHot=1`. A short-drama review has no `item_id`/`series_id`
/// request field: the series id travels as path `group_id` and
/// `business_param.book_id`.
struct PlayletCommentBody {
    series_id: String,
    sort: i64,
    count: i64,
    cursor: String,
    need_count: bool,
    tag: String,
    insert_ids: Vec<String>,
}

fn playlet_comment_body(p: &PlayletCommentBody) -> ApiResult<Vec<u8>> {
    let mut business = json!({
        "book_id": p.series_id,
        "need_count": p.need_count,
    });
    if !p.tag.is_empty() {
        business["tag"] = json!(p.tag);
    }
    if !p.insert_ids.is_empty() {
        business["insert_comment_ids"] = json!(p.insert_ids);
    }

    let mut body = json!({
        "business_param": business,
        "comment_source": 1,
        "comment_type": 2,
        "count": p.count,
        "group_id": p.series_id,
        "group_type": 1,
        "server_channel": 34,
        "sort": p.sort,
    });
    if !p.cursor.is_empty() {
        body["cursor"] = json!(p.cursor);
    }
    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))
}

/// The official playlet danmaku (弹幕) parameter set.
///
/// `DanmakuRequestHelper.java:314-329`: danmaku reuses the comment list
/// endpoint with the **video id** as `group_id`, `group_type=30`
/// (SeriesVideo), `comment_source=601`, `server_channel=1000`,
/// `comment_type=20` and `count=90`. `start_offset_time` and
/// `playlet_item_duration` are **milliseconds** — the official code multiplies
/// the duration by 1000 before sending it.
struct PlayletDanmakuBody {
    vid: String,
    series_id: String,
    start_offset_ms: i64,
    duration_ms: i64,
    cursor: String,
}

fn playlet_danmaku_body(p: &PlayletDanmakuBody) -> ApiResult<Vec<u8>> {
    let mut body = json!({
        "business_param": {
            "book_id": p.series_id,
            "playlet_item_duration": p.duration_ms,
            "start_offset_time": p.start_offset_ms,
        },
        "comment_source": 601,
        "comment_type": 20,
        "count": 90,
        "group_id": p.vid,
        "group_type": 30,
        "server_channel": 1000,
        "sort": 1,
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

/// `GET /api/v1/series/:series_id/comments` -> 官方短剧剧评列表。
fn handle_playlet_comments<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let series_id = params.get_str("series_id");
        if series_id.is_empty() {
            return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
        }

        // 「首页」与「加载更多」共用一条请求：need_count 只在首页为 true，
        // 官方由 cursor 是否为空推导（gx1/m.java:179/190/245）。
        let cursor = params.get_str("cursor");
        let need_count = match params.get_str("need_count").as_str() {
            "true" => true,
            "false" => false,
            _ => cursor.is_empty(),
        };

        let body = playlet_comment_body(&PlayletCommentBody {
            series_id: series_id.clone(),
            // SmartHot(1) 是官方默认；「最新」传 TimeDesc(3)。
            sort: int_default(&params.get_str("sort"), 1),
            count: int_default(&params.get_str("count"), 10),
            cursor,
            need_count,
            tag: params.get_str("tag"),
            insert_ids: split_csv(&params.get_str("insert_comment_ids")),
        })?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: format!("{BOOK_REVIEWS_PATH}{}/v1/", go_path_escape(&series_id)),
                params: reading724_params(),
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

/// 官方写评论的请求体（`AddCommentRequest` + `gx1/p0` / `hy1/l`）。
///
/// `res` 字段名全部来自 `AddCommentRequest.java:17-47`：
/// `text`、`group_id`、`group_type`、`comment_type`、`commit_source`、
/// `data_type`、`business_param`、`rich_text`，外加 query 上的 `aid`。
///
/// 短剧剧评（`community/impl/comment/playlet/editor/p0.java:211-256`）：
/// `group_id`=seriesId、`group_type=Book(1)`、`comment_type=UserActualComment(0)`、
/// `data_type` 由调用点给（快捷评星用 `FakeBook(3)`，见
/// `kr1/n.java:241`）、`commit_source=NovelPlayletCommentAdd(12)`、
/// `business_param.book_id`=seriesId。
///
/// 弹幕（`hy1/l.java:86-113`）：`group_id`=vid、`group_type=SeriesVideo(30)`、
/// `data_type=Danmaku(20)`、`commit_source=NovelItemDanmakuAdd(1500)`、
/// `business_param.offset` 毫秒、`business_param.shark_param={type:"short_play"}`。
struct PlayletCommentAddBody {
    text: String,
    group_id: String,
    group_type: i64,
    comment_type: i64,
    commit_source: i64,
    data_type: i64,
    book_id: String,
    score: i64,
    offset_ms: i64,
    shark_type: String,
    vid: String,
}

fn playlet_comment_add_body(p: &PlayletCommentAddBody) -> ApiResult<Vec<u8>> {
    let mut business = json!({
        "book_id": p.book_id,
        "score": p.score,
    });
    if p.offset_ms > 0 {
        business["offset"] = json!(p.offset_ms);
    }
    if !p.shark_type.is_empty() {
        business["shark_param"] = json!({ "type": p.shark_type });
    }
    let mut body = json!({
        "business_param": business,
        "comment_type": p.comment_type,
        "commit_source": p.commit_source,
        "data_type": p.data_type,
        "group_id": p.group_id,
        "group_type": p.group_type,
        "text": p.text,
    });
    if !p.vid.is_empty() {
        body["vid"] = json!(p.vid);
    }
    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))
}

/// 官方热评请求的固定取值（`a13/w.java:563-599`）。
///
/// 热评**没有独立接口字段**：同一次 `comment/list` 返回的列表就是热评来源
/// （客户端按 `dataType` 筛，见 Dart 侧 `hotOf`）。与剧评面板的区别是
/// `comment_source=NovelItemComment(4)`、`comment_type=NewItem(4)`、
/// `group_type=SeriesVideo(30)`、`count=20`，并且**返回的
/// `common_list_info.total` 就是右栏评论计数**（`SeriesCommentView` 读的
/// `du4.a.e()`，见 `a13/w.java:500`）。
struct PlayletHotCommentBody {
    series_id: String,
    vid: String,
    server_channel: i64,
    insert_ids: Vec<String>,
}

fn playlet_hot_comment_body(p: &PlayletHotCommentBody) -> ApiResult<Vec<u8>> {
    // 官方的 group_id/book_id 取 vid 还是剧集 id 由「是不是书场景」决定
    // （`jVar.C()`）；剧集播放页走 SeriesVideo 分支，两者都用 vid。
    let group_id = if p.vid.is_empty() {
        p.series_id.clone()
    } else {
        p.vid.clone()
    };
    let mut business = json!({
        "book_id": group_id,
        "need_count": true,
    });
    if !p.insert_ids.is_empty() {
        business["insert_comment_ids"] = json!(p.insert_ids);
    }
    let body = json!({
        "business_param": business,
        "comment_source": 4,
        "comment_type": 4,
        "count": 20,
        "group_id": group_id,
        "group_type": 30,
        "server_channel": p.server_channel,
        "sort": 1,
    });
    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))
}

/// `GET /api/v1/videos/:vid/hot-comments?series_id=…` -> 官方热评 + 评论计数。
///
/// `server_channel` 由调用场景决定（`FanqieHotCommentArgsBrick.java:17-29`：
/// 17/26/37/48），场景到 channel 的映射**未取证**，所以由调用方给，缺省 17。
///
/// 官方评论点赞走**独立的 digg 接口**，不是 `do_action`
/// （`com/dragon/read/social/t.java:803-831`：`W(NovelComment)` 与
/// `Z(NovelReply)` 都构 `DiggRequest`）。
///
/// `DiggRequest` 字段（`rpc/model/DiggRequest.java:13-26`）：
/// `book_id`、`comment_id`、`digg_type`、`target_type`、`service_id`。
/// `DiggActionType`：Digg=1 / UnDigg=3（`kmp/reading/model/DiggActionType.java:12-13`）。
/// `DiggTargetType`：Comment=1 / Reply=2 / PlayletComment=5
/// （`kmp/reading/model/DiggTargetType.java:13-17`）。短剧评论该用哪个
/// target_type **未取证**，因此由调用方给，缺省 1。
fn handle_playlet_comment_digg<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let comment_id = params.get_str("comment_id");
        if comment_id.is_empty() {
            return Err(ApiError::BadRequest("缺少comment_id参数".to_string()));
        }
        let liked = params.get_str("liked") != "false";
        let mut body = json!({
            "comment_id": comment_id,
            "digg_type": if liked { 1 } else { 3 },
            "target_type": int_default(&params.get_str("target_type"), 1),
        });
        let book_id = params.get_str("book_id");
        if !book_id.is_empty() {
            body["book_id"] = json!(book_id);
        }

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: COMMENT_DIGG_PATH.to_string(),
                params: reading724_params(),
                body: Some(
                    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))?,
                ),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

/// 官方回复短剧评论（`community/impl/comment/playlet/.../nx1/d.java:217-231`）：
/// `commit_source=NovelPlayletReplyAdd(13)`、`group_type=Book(1)`、
/// `data_type=Book(2)`，并带 `reply_to_comment_id`/`reply_to_user_id`/`reply_to_replyid`。
fn handle_playlet_comment_reply<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let text = params.get_str("text");
        if text.trim().is_empty() {
            return Err(ApiError::BadRequest("缺少text参数".to_string()));
        }
        let series_id = params.get_str("series_id");
        if series_id.is_empty() {
            return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
        }
        let reply_to_comment_id = params.get_str("reply_to_comment_id");
        if reply_to_comment_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少reply_to_comment_id参数".to_string(),
            ));
        }

        let mut body = json!({
            "business_param": { "book_id": series_id },
            "commit_source": 13,
            "data_type": 2,
            "group_id": series_id,
            "group_type": 1,
            "reply_to_comment_id": reply_to_comment_id,
            "text": text,
        });
        // 二级回复才带这两个：官方只在有值时序列化。
        for (key, value) in [
            ("reply_to_replyid", params.get_str("reply_to_reply_id")),
            ("reply_to_userid", params.get_str("reply_to_user_id")),
        ] {
            if !value.is_empty() {
                body[key] = json!(value);
            }
        }

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: COMMENT_REPLY_ADD_PATH.to_string(),
                params: reading724_params(),
                body: Some(
                    serde_json::to_vec(&body).map_err(|e| ApiError::Internal(e.to_string()))?,
                ),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

/// `POST /api/v1/series/:id/comments/add` -> 官方发评论（剧评或弹幕共用一条上游）。
///
/// 上游是 `POST /novel/commentapi/comment/add/v1/`，`mode` 决定用哪一组枚举：
/// `comment`（默认）= 短剧剧评，`danmaku` = 弹幕。`aid` 走 query
/// （`AddCommentRequest.appID` 标了 `@RpcField(QUERY)`）。
fn handle_playlet_comment_add<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let text = params.get_str("text");
        if text.trim().is_empty() {
            return Err(ApiError::BadRequest("缺少text参数".to_string()));
        }
        let series_id = params.get_str("series_id");
        if series_id.is_empty() {
            return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
        }
        let is_danmaku = params.get_str("mode") == "danmaku";
        let vid = params.get_str("vid");
        if is_danmaku && vid.is_empty() {
            return Err(ApiError::BadRequest("缺少vid参数".to_string()));
        }

        // 弹幕：group_id=vid、group_type=SeriesVideo(30)、data_type=Danmaku(20)、
        // commit_source=NovelItemDanmakuAdd(1500)、book_id 取剧集 id、offset 毫秒。
        // 剧评：group_id=seriesId、group_type=Book(1)、
        // commit_source=NovelPlayletCommentAdd(12)。
        // vid 在弹幕分支里同时要当 group_id 和（剧评分支的）可选字段，
        // 先克隆一份给 body，避免所有权被 group_id 吃掉。
        let vid_for_body = vid.clone();
        let (group_id, group_type, data_type, commit_source, book_id) = if is_danmaku {
            (vid, 30, 20, 1500, series_id)
        } else {
            (
                series_id.clone(),
                1,
                int_default(&params.get_str("data_type"), 2),
                12,
                series_id,
            )
        };

        let body = playlet_comment_add_body(&PlayletCommentAddBody {
            text,
            group_id: group_id.clone(),
            group_type,
            // UgcNovelCommentType.UserActualComment = 0（p0.java:215）。
            comment_type: int_default(&params.get_str("comment_type"), 0),
            commit_source,
            data_type,
            book_id,
            score: int_default(&params.get_str("score"), 0),
            offset_ms: if is_danmaku {
                int_default(&params.get_str("offset"), 0)
            } else {
                0
            },
            shark_type: if is_danmaku {
                "short_play".to_string()
            } else {
                String::new()
            },
            vid: if is_danmaku {
                String::new()
            } else {
                vid_for_body
            },
        })?;

        let mut query = reading724_params();
        set_param(&mut query, "aid", "1967");

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: COMMENT_ADD_PATH.to_string(),
                params: query,
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_playlet_hot_comments<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let series_id = params.get_str("series_id");
        if series_id.is_empty() {
            return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
        }
        let vid = params.get_str("vid");
        let group_id = if vid.is_empty() {
            series_id.clone()
        } else {
            vid.clone()
        };

        let body = playlet_hot_comment_body(&PlayletHotCommentBody {
            series_id,
            vid,
            server_channel: int_default(&params.get_str("server_channel"), 17),
            insert_ids: split_csv(&params.get_str("insert_comment_ids")),
        })?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: format!("{BOOK_REVIEWS_PATH}{}/v1/", go_path_escape(&group_id)),
                params: reading724_params(),
                body: Some(body),
                headers: dragon_read_json_headers(),
                ..Default::default()
            })
            .await
    })
}

/// `GET /api/v1/videos/:vid/danmaku?series_id=…` -> 官方短剧弹幕取数。
///
/// 弹幕没有独立上游 path，它复用短剧评论列表；`group_id` 是 **vid**，
/// `book_id` 才是剧集 id，两者缺一不可，所以 `series_id` 必填。
fn handle_playlet_danmaku<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let vid = params.get_str("vid");
        if vid.is_empty() {
            return Err(ApiError::BadRequest("缺少vid参数".to_string()));
        }
        let series_id = params.get_str("series_id");
        if series_id.is_empty() {
            return Err(ApiError::BadRequest("缺少series_id参数".to_string()));
        }

        // 两端都是毫秒：start_offset_time 直接就是当前进度，
        // playlet_item_duration 由秒 ×1000 得到（DanmakuRequestHelper.java:325-327）。
        let duration_ms = match params.get_str("playlet_item_duration") {
            v if v.is_empty() => 0,
            v => int_default(&v, 0).saturating_mul(1000),
        };

        let body = playlet_danmaku_body(&PlayletDanmakuBody {
            vid: vid.clone(),
            series_id,
            start_offset_ms: int_default(&params.get_str("start_offset_time"), 0),
            duration_ms,
            cursor: params.get_str("cursor"),
        })?;

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                method: Some("POST".to_string()),
                host: HOST_FQNOVEL.to_string(),
                path: format!("{BOOK_REVIEWS_PATH}{}/v1/", go_path_escape(&vid)),
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
    s.add_route("playlet_comments", handle_playlet_comments);
    s.add_route("playlet_danmaku", handle_playlet_danmaku);
    s.add_route("playlet_hot_comments", handle_playlet_hot_comments);
    s.add_route("playlet_comment_add", handle_playlet_comment_add);
    s.add_route("playlet_comment_digg", handle_playlet_comment_digg);
    s.add_route("playlet_comment_reply", handle_playlet_comment_reply);
    s.add_route("idea_list", handle_idea_list);
    s.add_route("book_comments_legacy", handle_book_comments_legacy);
    s.add_route("comment_replies", handle_comment_replies);
    s.add_route("chapter_summary", handle_chapter_summary);
}
