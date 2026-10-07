//! Short-drama comment, danmaku and share contract tests.
//!
//! Every expectation is derived from the official 7.0.9.32 decompilation (see
//! .agents/notes/proposed/architecture/2026-09-25-f04-official-evidence.md),
//! not from the Rust implementation: each case pins the upstream path, the
//! JSON body fields and the query bag the official client sends.
//!
//! The three families share one upstream endpoint family:
//! `POST /novel/commentapi/comment/list/:group_id/v1/` for 剧评、热评、弹幕取数.

mod common;

use common::{build_server, pool_json, start_loopback, MockReply, MockUpstream, TempDir};
use fqapi_core::dispatch::{dispatch, Request};
use serde_json::{json, Value};
use std::sync::Arc;

async fn server_with(dir: &TempDir, origin: &str) -> Arc<fqapi_core::endpoints::Server> {
    build_server(dir, Some(origin.to_string()), &[], &[], &pool_json(5)).await
}

fn api_get(path: &str, query: &str) -> Request {
    Request {
        method: "GET".to_string(),
        path: path.to_string(),
        query: query.to_string(),
        body: Vec::new(),
        headers: Vec::new(),
    }
}

fn api_post(path: &str, query: &str, body: &str) -> Request {
    Request {
        method: "POST".to_string(),
        path: path.to_string(),
        query: query.to_string(),
        body: body.as_bytes().to_vec(),
        headers: Vec::new(),
    }
}

async fn json_body(resp: fqapi_core::dispatch::Response) -> (u16, Value) {
    let status = resp.status;
    let bytes = resp.into_bytes().await.expect("body");
    let value = serde_json::from_slice(&bytes).unwrap_or_else(|e| {
        panic!(
            "response is not JSON ({e}): {}",
            String::from_utf8_lossy(&bytes)
        )
    });
    (status, value)
}

fn body_of(recorded: &common::Recorded) -> Value {
    serde_json::from_slice(&recorded.body).expect("upstream body is JSON")
}

#[tokio::test]
async fn write_routes_reject_get_before_any_upstream_request() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0}))).await;
    let dir = TempDir::new("playlet-write-method");
    let server = server_with(&dir, &upstream.origin).await;
    for (path, query) in [
        ("/api/v1/series/123/comments/add", "text=x"),
        ("/api/v1/videos/456/danmaku/add", "series_id=123&text=x"),
        ("/api/v1/comments/c9/reply", "series_id=123&text=x"),
        ("/api/v1/comments/c9/digg", "liked=true"),
    ] {
        let response = dispatch(&server, &api_get(path, query)).await;
        assert_eq!(response.status, 405, "GET {path}");
        assert!(response
            .headers
            .iter()
            .any(|(name, value)| { name.eq_ignore_ascii_case("allow") && value == "POST" }));
    }
    assert!(upstream.requests().is_empty());

    // Exercise the actual loopback adapter as well as direct dispatch.
    let lb = start_loopback(server).await;
    let response = reqwest::get(lb.url("/api/v1/series/123/comments/add?text=x"))
        .await
        .expect("loopback GET");
    assert_eq!(response.status().as_u16(), 405);
    assert_eq!(response.headers()["allow"], "POST");
    assert!(upstream.requests().is_empty());
    lb.task.abort();
    upstream.shutdown();
}

/// y.java 的短剧回复参数不同于段评：Book(2/1)、NovelBookReply(501)、
/// NovelPlayletCommentInnerList(34)、RealLevel3ReplyL2(3)。
#[tokio::test]
async fn anonymous_playlet_replies_use_the_series_context_and_official_enums() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({
            "code": 0,
            "data": {"common_list_info": {"cursor": "next", "has_more": true, "total": 2}}
        }))
    })
    .await;
    let dir = TempDir::new("playlet-replies-list");
    let server = server_with(&dir, &upstream.origin).await;
    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/123/comments/c9/replies", "count=10"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["data"]["common_list_info"]["cursor"], "next");
    let request = upstream.last_request().expect("call");
    assert_eq!(request.method, "POST");
    assert_eq!(request.path, "/novel/commentapi/reply/list/c9/v1/");
    assert!(request.query.contains("aid=1967"));
    let sent = body_of(&request);
    assert_eq!(sent["comment_id"], "c9");
    assert_eq!(sent["group_id"], "123");
    assert_eq!(sent["comment_type"], 2);
    assert_eq!(sent["group_type"], 1);
    assert_eq!(sent["comment_source"], 501);
    assert_eq!(sent["server_channel"], 34);
    assert_eq!(sent["count"], 10);
    assert_eq!(sent["business_param"]["book_id"], "123");
    assert_eq!(sent["business_param"]["need_count"], true);
    assert_eq!(sent["business_param"]["real_level"], 3);
    assert!(sent["business_param"].get("insert_reply_ids").is_none());
    assert!(sent["business_param"].get("client_ab_params").is_none());

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/123/comments/c9/replies", "cursor=next"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("next page"));
    assert_eq!(sent["cursor"], "next");
    // 未传 count 时落官方默认每页 5 条（`y.java:97-98` static{o=5;p=5}）。
    assert_eq!(sent["count"], 5);
    assert!(sent["business_param"].get("insert_reply_ids").is_none());
    upstream.shutdown();
}

/// 回复型热评/消息中心的定点读（`y.java` L():1163-1203）：
/// comment_source=NovelBookReplyMessage(1002)，business_param 追加
/// ref_reply_id + insert_reply_ids；普通分页（501）不受影响。
#[tokio::test]
async fn playlet_reply_pinpoint_read_uses_source_1002_with_ref_reply() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({
            "code": 0,
            "data": {"common_list_info": {"cursor": "", "has_more": false}}
        }))
    })
    .await;
    let dir = TempDir::new("playlet-replies-pinpoint");
    let server = server_with(&dir, &upstream.origin).await;
    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/123/comments/c9/replies", "ref_reply_id=r7"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("pinpoint call"));
    assert_eq!(sent["comment_source"], 1002);
    assert_eq!(sent["business_param"]["ref_reply_id"], "r7");
    assert_eq!(sent["business_param"]["insert_reply_ids"], json!(["r7"]));
    assert_eq!(sent["count"], 5);
    upstream.shutdown();
}

#[tokio::test]
async fn anonymous_playlet_replies_refuse_missing_context_without_an_upstream_call() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0}))).await;
    let dir = TempDir::new("playlet-replies-missing");
    let server = server_with(&dir, &upstream.origin).await;
    for path in [
        "/api/v1/series//comments/c9/replies",
        "/api/v1/series/123/comments//replies",
    ] {
        let (status, _) = json_body(dispatch(&server, &api_get(path, "")).await).await;
        assert_eq!(status, 400);
    }
    assert!(upstream.requests().is_empty());
    upstream.shutdown();
}

/// 官方短剧剧评（`gx1/m.java:168-181`）：
/// path 的 group_id = seriesId；comment_source=1、server_channel=34、
/// group_type=1（Book）、comment_type=2（Book）、sort=1（SmartHot）、count=10、
/// business_param.book_id=seriesId、need_count=true（首页）。
#[tokio::test]
async fn playlet_comment_list_matches_the_official_request() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"common_list_info": {"cursor": "c1"}}}))
    })
    .await;
    let dir = TempDir::new("playlet-comments");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/7491705400958405694/comments", "count=10"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["code"], 0);

    let request = upstream.last_request().expect("one upstream call");
    assert_eq!(request.method, "POST");
    assert_eq!(
        request.path, "/novel/commentapi/comment/list/7491705400958405694/v1/",
        "path 的 group_id 是 seriesId"
    );

    let sent = body_of(&request);
    assert_eq!(sent["group_id"], "7491705400958405694");
    assert_eq!(sent["comment_source"], 1);
    assert_eq!(sent["server_channel"], 34);
    assert_eq!(sent["group_type"], 1);
    assert_eq!(sent["comment_type"], 2);
    assert_eq!(sent["sort"], 1);
    assert_eq!(sent["count"], 10);
    assert_eq!(sent["business_param"]["book_id"], "7491705400958405694");
    assert_eq!(sent["business_param"]["need_count"], true);
    assert!(
        sent.get("cursor").is_none(),
        "首页不带 cursor（gx1/m.java:187）"
    );
    assert!(
        sent.get("item_id").is_none() && sent.get("series_id").is_none(),
        "短剧评论族没有 item_id / series_id 请求字段"
    );
    upstream.shutdown();
}

/// 分页：加载更多带 cursor 且 need_count=false（`gx1/m.java:242-245`）。
#[tokio::test]
async fn playlet_comment_paging_carries_the_cursor() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comments-page");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get(
                "/api/v1/series/123/comments",
                "cursor=CURSOR-A&count=10&need_count=false",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("call"));
    assert_eq!(sent["cursor"], "CURSOR-A");
    assert_eq!(sent["business_param"]["need_count"], false);
    upstream.shutdown();
}

/// 排序：「最新」= TimeDesc(3)，其余标签带 `business_param.tag`
/// （`gx1/n0.java:1631-1645`、`gx1/m.java:152-159`）。
#[tokio::test]
async fn playlet_comment_sort_and_tag_reach_upstream() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comments-sort");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/123/comments", "sort=3&tag=TAG-9&count=20"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("call"));
    assert_eq!(sent["sort"], 3);
    assert_eq!(sent["business_param"]["tag"], "TAG-9");
    assert_eq!(sent["count"], 20);
    upstream.shutdown();
}

/// 弹幕取数（`DanmakuRequestHelper.java:314-329`）：path 的 group_id 是 vid、
/// group_type=30（SeriesVideo）、comment_source=601、server_channel=1000、
/// comment_type=20、count=90；时间单位毫秒。
#[tokio::test]
async fn playlet_danmaku_list_uses_vid_and_milliseconds() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-danmaku");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get(
                "/api/v1/videos/VID-1/danmaku",
                "series_id=123&start_offset_time=12500&playlet_item_duration=305",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);

    let request = upstream.last_request().expect("call");
    assert_eq!(request.method, "POST");
    assert_eq!(
        request.path, "/novel/commentapi/comment/list/VID-1/v1/",
        "弹幕 path 的 group_id 是 vid，不是 seriesId"
    );
    let sent = body_of(&request);
    assert_eq!(sent["group_id"], "VID-1");
    assert_eq!(sent["group_type"], 30);
    assert_eq!(sent["comment_source"], 601);
    assert_eq!(sent["server_channel"], 1000);
    assert_eq!(sent["comment_type"], 20);
    assert_eq!(sent["sort"], 1);
    assert_eq!(sent["count"], 90);
    assert_eq!(sent["business_param"]["book_id"], "123");
    assert_eq!(sent["business_param"]["start_offset_time"], 12500);
    assert_eq!(
        sent["business_param"]["playlet_item_duration"], 305000,
        "秒 -> 毫秒（DanmakuRequestHelper.java:327）"
    );
    upstream.shutdown();
}

/// 剧集 id 缺失时弹幕请求必须失败，而不是退化成 vid 当 book_id。
#[tokio::test]
async fn playlet_danmaku_requires_the_series_id() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-danmaku-missing");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/videos/VID-1/danmaku", "start_offset_time=0"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 400);
    assert!(
        body["error"]
            .as_str()
            .unwrap_or_default()
            .contains("series_id"),
        "错误信息要指出缺的是 series_id"
    );
    assert!(upstream.requests().is_empty(), "参数不全会打上游");
    upstream.shutdown();
}

/// 短剧分享（`m0.java:938-957`）：`share_type=7`（Video）而不是书籍的 0，
/// 且带上剧集上下文字段。
#[tokio::test]
async fn playlet_share_requests_video_share_type() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"share_url": "https://example.test/s"}}))
    })
    .await;
    let dir = TempDir::new("playlet-share");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get(
                "/api/v1/series/123/share",
                "album_id=123&current_chapter_id=VID-2&first_chapter_id=VID-1                 &share_timestamp=1700000000&entrance=1",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["data"]["share_url"], "https://example.test/s");

    let request = upstream.last_request().expect("call");
    assert!(
        request.path.starts_with("/reading/user/share/info/v"),
        "分享信息路径: {}",
        request.path
    );
    let query = request.query.as_str();
    for expected in [
        "share_type=7",
        "album_id=123",
        "group_id=123",
        "current_chapter_id=VID-2",
        "first_chapter_id=VID-1",
        "share_timestamp=1700000000",
        "entrance=1",
    ] {
        assert!(query.contains(expected), "query 缺少 {expected}: {query}");
    }
    upstream.shutdown();
}

/// 热评复用同一次列表请求（`a13/w.java:563-599`）：`:group_id` 是 vid、
/// `comment_source=4`、`comment_type=4`、`group_type=30`、`count=20`、
/// `business_param.book_id` 在剧集场景也是 vid；返回的 total 就是右栏计数。
#[tokio::test]
async fn playlet_hot_comments_match_the_official_request() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"common_list_info": {"total": 42}}}))
    })
    .await;
    let dir = TempDir::new("playlet-hot");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/123/hot-comments", "vid=VID-7"),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["data"]["common_list_info"]["total"], 42);

    let request = upstream.last_request().expect("call");
    assert_eq!(
        request.path, "/novel/commentapi/comment/list/VID-7/v1/",
        "热评的 group_id 是 vid"
    );
    let sent = body_of(&request);
    assert_eq!(sent["group_id"], "VID-7");
    assert_eq!(sent["comment_source"], 4);
    assert_eq!(sent["comment_type"], 4);
    assert_eq!(sent["group_type"], 30);
    assert_eq!(sent["sort"], 1);
    assert_eq!(sent["count"], 20);
    assert_eq!(sent["business_param"]["book_id"], "VID-7");
    assert_eq!(sent["business_param"]["need_count"], true);
    assert_eq!(sent["server_channel"], 17, "缺省场景 channel");
    upstream.shutdown();
}

/// 调用方可以覆盖场景 channel（官方按场景取 17/26/37/48）。
#[tokio::test]
async fn playlet_hot_comments_accept_the_scene_channel() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-hot-channel");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get(
                "/api/v1/series/123/hot-comments",
                "vid=VID-7&server_channel=48",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("call"));
    assert_eq!(sent["server_channel"], 48);
    upstream.shutdown();
}

/// 没有 vid 时热评退化到剧集 id 作为 group_id（官方 `jVar.C()` 的书场景分支）。
#[tokio::test]
async fn playlet_hot_comments_fall_back_to_the_series_id() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-hot-book");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) =
        json_body(dispatch(&server, &api_get("/api/v1/series/123/hot-comments", "")).await).await;
    assert_eq!(status, 200);
    let request = upstream.last_request().expect("call");
    assert_eq!(request.path, "/novel/commentapi/comment/list/123/v1/");
    let sent = body_of(&request);
    assert_eq!(sent["group_id"], "123");
    assert_eq!(sent["business_param"]["book_id"], "123");
    upstream.shutdown();
}

/// 发短剧剧评（`community/impl/comment/playlet/editor/p0.java:211-256`）：
/// 上游 `comment/add/v1/`，`group_id`=seriesId、`group_type=Book(1)`、
/// `comment_type=UserActualComment(0)`、`commit_source=NovelPlayletCommentAdd(12)`、
/// `business_param.book_id`=seriesId，且 `aid` 走 query。
#[tokio::test]
async fn playlet_comment_add_matches_the_official_request() {
    let upstream = MockUpstream::start(|_| {
        MockReply::json(json!({"code": 0, "data": {"comment_info": {"comment_id": "c9"}}}))
    })
    .await;
    let dir = TempDir::new("playlet-comment-add");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_post("/api/v1/series/123/comments/add", "text=好看&score=5", ""),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["data"]["comment_info"]["comment_id"], "c9");

    let request = upstream.last_request().expect("call");
    assert_eq!(request.path, "/novel/commentapi/comment/add/v1/");
    assert!(
        request.query.contains("aid=1967"),
        "aid 走 query: {}",
        request.query
    );
    let sent = body_of(&request);
    assert_eq!(sent["text"], "好看");
    assert_eq!(sent["group_id"], "123");
    assert_eq!(sent["group_type"], 1);
    assert_eq!(sent["comment_type"], 0);
    assert_eq!(sent["commit_source"], 12);
    assert_eq!(sent["business_param"]["book_id"], "123");
    assert_eq!(sent["business_param"]["score"], 5);
    assert!(
        sent.get("offset").is_none() && sent["business_param"].get("offset").is_none(),
        "剧评不带弹幕的 offset"
    );
    upstream.shutdown();
}

/// 发弹幕（`hy1/l.java:86-113`）：`group_id`=vid、`group_type=SeriesVideo(30)`、
/// `data_type=Danmaku(20)`、`commit_source=NovelItemDanmakuAdd(1500)`、
/// `business_param.offset` 毫秒、`shark_param.type=short_play`。
#[tokio::test]
async fn playlet_danmaku_add_matches_the_official_request() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-danmaku-add");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_post(
                "/api/v1/videos/VID-3/danmaku/add",
                "text=前方高能&series_id=123&offset=12500",
                "",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let request = upstream.last_request().expect("call");
    assert_eq!(request.path, "/novel/commentapi/comment/add/v1/");
    let sent = body_of(&request);
    assert_eq!(sent["group_id"], "VID-3");
    assert_eq!(sent["group_type"], 30);
    assert_eq!(sent["data_type"], 20);
    assert_eq!(sent["commit_source"], 1500);
    assert_eq!(sent["business_param"]["book_id"], "123");
    assert_eq!(sent["business_param"]["offset"], 12500);
    assert_eq!(sent["business_param"]["shark_param"]["type"], "short_play");
    upstream.shutdown();
}

/// 空文本必须被拒绝，而且完全不打上游（官方编辑器在 UI 层就挡住空串）。
#[tokio::test]
async fn playlet_comment_add_rejects_an_empty_text() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comment-add-empty");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_post("/api/v1/series/123/comments/add", "text=%20%20", ""),
        )
        .await,
    )
    .await;
    assert_eq!(status, 400);
    assert!(body["error"].as_str().unwrap_or_default().contains("text"));
    assert!(upstream.requests().is_empty());
    upstream.shutdown();
}

/// 发弹幕缺 vid 必须被拒绝（vid 是它的 group_id）。
#[tokio::test]
async fn playlet_danmaku_add_requires_the_vid() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-danmaku-add-missing");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_post("/api/v1/videos//danmaku/add", "text=x&series_id=123", ""),
        )
        .await,
    )
    .await;
    assert_eq!(status, 400);
    assert!(body["error"].as_str().unwrap_or_default().contains("vid"));
    assert!(upstream.requests().is_empty());
    upstream.shutdown();
}

/// 点赞短剧评论（`social/t.java:803-831`）：走独立 digg 接口而不是 do_action，
/// `digg_type` 1=Digg / 3=UnDigg。
#[tokio::test]
async fn playlet_comment_digg_matches_the_official_request() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comment-digg");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_post(
                "/api/v1/comments/c9/digg",
                "liked=true&book_id=123&target_type=5",
                "",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let request = upstream.last_request().expect("call");
    assert_eq!(request.path, "/reading/ugc/novel_comment/digg/v");
    let sent = body_of(&request);
    assert_eq!(sent["comment_id"], "c9");
    assert_eq!(sent["digg_type"], 1);
    assert_eq!(sent["target_type"], 5);
    assert_eq!(sent["book_id"], "123");
    upstream.shutdown();
}

/// 取消点赞用 UnDigg(3)。
#[tokio::test]
async fn playlet_comment_undigg_uses_the_cancel_action() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comment-undigg");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_post("/api/v1/comments/c9/digg", "liked=false", ""),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("call"));
    assert_eq!(sent["digg_type"], 3);
    assert!(
        sent.get("book_id").is_none(),
        "没给 book_id 时不能凭空造一个"
    );
    upstream.shutdown();
}

/// 回复短剧评论（`nx1/d.java:217-231`）：`commit_source=13`、`data_type=Book(2)`，
/// 一级回复只带 `reply_to_comment_id`。
#[tokio::test]
async fn playlet_comment_reply_matches_the_official_request() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comment-reply");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_post(
                "/api/v1/comments/c9/reply",
                "text=同感&series_id=123&reply_to_comment_id=c9",
                "",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let request = upstream.last_request().expect("call");
    assert_eq!(request.path, "/novel/commentapi/reply/add/v1/");
    let sent = body_of(&request);
    assert_eq!(sent["text"], "同感");
    assert_eq!(sent["group_id"], "123");
    assert_eq!(sent["group_type"], 1);
    assert_eq!(sent["commit_source"], 13);
    assert_eq!(sent["data_type"], 2);
    assert_eq!(sent["reply_to_comment_id"], "c9");
    assert_eq!(sent["business_param"]["book_id"], "123");
    assert!(sent.get("reply_to_replyid").is_none());
    upstream.shutdown();
}

/// 二级回复额外带 `reply_to_replyid` 与 `reply_to_userid`。
#[tokio::test]
async fn playlet_comment_second_level_reply_carries_the_parent_reply() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comment-reply-2");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_post(
                "/api/v1/comments/c9/reply",
                "text=同意&series_id=123&reply_to_comment_id=c9                 &reply_to_reply_id=r1&reply_to_user_id=u7",
                "",
            ),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let sent = body_of(&upstream.last_request().expect("call"));
    assert_eq!(sent["reply_to_replyid"], "r1");
    assert_eq!(sent["reply_to_userid"], "u7");
    upstream.shutdown();
}

/// 回复缺 reply_to_comment_id 必须被拒绝。
#[tokio::test]
async fn playlet_comment_reply_requires_the_target_comment() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-comment-reply-missing");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, body) = json_body(
        dispatch(
            &server,
            &api_post("/api/v1/comments/c9/reply", "text=x&series_id=123", ""),
        )
        .await,
    )
    .await;
    assert_eq!(status, 400);
    assert!(body["error"]
        .as_str()
        .unwrap_or_default()
        .contains("reply_to_comment_id"));
    assert!(upstream.requests().is_empty());
    upstream.shutdown();
}

/// 剧集 id 就是 group_id：路由必须从路径补齐 `group_id`/`album_id`，
/// 调用方不传也不能丢（官方 model 里两者同源，`m0.java:938-957`）。
#[tokio::test]
async fn playlet_share_fills_group_id_from_the_series_id() {
    let upstream = MockUpstream::start(|_| MockReply::json(json!({"code": 0, "data": {}}))).await;
    let dir = TempDir::new("playlet-share-fill");
    let server = server_with(&dir, &upstream.origin).await;

    let (status, _) = json_body(
        dispatch(
            &server,
            &api_get("/api/v1/series/7491705400958405694/share", ""),
        )
        .await,
    )
    .await;
    assert_eq!(status, 200);
    let query = upstream.last_request().expect("call").query;
    assert!(query.contains("group_id=7491705400958405694"), "{query}");
    assert!(query.contains("album_id=7491705400958405694"), "{query}");
    assert!(query.contains("share_type=7"), "{query}");
    upstream.shutdown();
}
