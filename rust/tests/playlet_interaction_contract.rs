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

use common::{build_server, pool_json, MockReply, MockUpstream, TempDir};
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
