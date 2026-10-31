//! 书旗数据源的契约测试：路由、请求形状、四条解析/兜底路径。
//!
//! 全程离线：`mock_origin` 会把任意绝对 URL 改写成本地 mock，所以书旗的
//! `ocean.shuqireader.com`、`www.shuqi.com`、`c1/c2.shuqireader.com` 都落到
//! 同一个 mock handler 上，按 path 分支回复。

mod common;

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use common::{build_server, pool_json, MockReply, MockUpstream, Recorded, TempDir};
use fqapi_core::endpoints::{router, Params};
use serde_json::json;
use std::sync::Arc;

async fn server(dir: &TempDir, origin: &str) -> Arc<fqapi_core::endpoints::Server> {
    build_server(dir, Some(origin.to_string()), &[], &[], &pool_json(1)).await
}

fn text(body: &str) -> MockReply {
    MockReply {
        status: 200,
        headers: vec![(
            "content-type".to_string(),
            "text/html; charset=utf-8".to_string(),
        )],
        body: body.as_bytes().to_vec(),
    }
}

// --- 路由 ------------------------------------------------------------------

#[test]
fn routes_map_to_shuqi_endpoints() {
    for (path, api) in [
        ("/api/v1/shuqi/search", "shuqi_search"),
        ("/api/v1/shuqi/book", "shuqi_book"),
        ("/api/v1/shuqi/toc", "shuqi_toc"),
        ("/api/v1/shuqi/chapter", "shuqi_chapter"),
    ] {
        let m = router::match_rest_path(path, &Params::new()).expect(path);
        assert_eq!(m.api, api, "{path}");
    }
    // 未知动作不能落到别的数据源上。
    assert!(router::match_rest_path("/api/v1/shuqi/nope", &Params::new()).is_none());
    assert!(router::match_rest_path("/api/v1/shuqi", &Params::new()).is_none());
}

// --- 搜索 ------------------------------------------------------------------

#[tokio::test]
async fn search_posts_encrypted_form_and_collects_books() {
    let upstream = MockUpstream::start(|_: &Recorded| {
        MockReply::json(json!({
            "data": {
                "module_list": [
                    {
                        "bookId": "34078",
                        "bookName": "凡人修仙传",
                        "authorName": "忘语",
                        "imgUrl": "https://img/34078.jpg",
                        "wordCount": 2451000,
                        "serialState": "2",
                        "categoryName": "玄幻",
                        "tagList": [{ "tagName": "修仙" }],
                        "latestChapterName": "第2451章 山边小村"
                    },
                    {
                        // 去重：同名同作者的第二份必须被丢掉
                        "bookId": "34078",
                        "bookName": "凡人修仙传",
                        "authorName": "忘语",
                        "briefIntro": "重复项"
                    }
                ]
            }
        }))
    })
    .await;

    let dir = TempDir::new("shuqi-search");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_search").expect("route registered");
    let params = Params::from_pairs(vec![("key".to_string(), "凡人".to_string())]);
    let value = handler(&srv.ctx, &params).await.expect("search");

    let rec = upstream.last_request().expect("upstream call");
    assert_eq!(rec.method, "POST");
    assert_eq!(rec.path, "/sqan/render/render/search/native_v3");
    assert_eq!(rec.header("user-agent"), Some("okhttp/3.12.13"));
    assert_eq!(rec.header("x-sq-req-platform"), Some("an"));
    assert!(
        rec.header("x-sq-public").is_some(),
        "signature header missing"
    );
    assert_eq!(rec.header("x-sq-api-encrypt"), Some("1"));
    let body = String::from_utf8_lossy(&rec.body);
    assert!(body.starts_with("data="), "encrypted form body: {body}");

    let list = value["data"].as_array().expect("list");
    assert_eq!(list.len(), 1, "duplicates must collapse");
    assert_eq!(list[0]["bookId"], "34078");
    assert_eq!(list[0]["name"], "凡人修仙传");
    assert_eq!(list[0]["author"], "忘语");
    assert_eq!(list[0]["status"], "完结");
    assert_eq!(list[0]["bookUrl"], "/sqbook/34078");
    assert_eq!(list[0]["source"], "shuqi");
    assert_eq!(value["source"], "shuqi");
}

#[tokio::test]
async fn search_without_key_is_bad_request() {
    let upstream = MockUpstream::start(|_: &Recorded| MockReply::status(500)).await;
    let dir = TempDir::new("shuqi-search-nokey");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_search").expect("route registered");
    let err = handler(&srv.ctx, &Params::new())
        .await
        .expect_err("missing key must fail");
    assert_eq!(err.status(), 400);
}

// --- 详情 ------------------------------------------------------------------

#[tokio::test]
async fn titlepage_maps_book_info() {
    let upstream = MockUpstream::start(|_: &Recorded| {
        MockReply::json(json!({
            "data": {
                "bookInfo": {
                    "bookId": 34078,
                    "bookName": "凡人修仙传",
                    "authorName": "忘语",
                    "desc": "一个普通山村小子……",
                    "className": "玄幻",
                    "tagList": [{ "tagName": "修仙" }, "热血"],
                    "serialState": "2",
                    "scoreInfo": { "bookScore": "9.2" },
                    "wordCount": 24510000,
                    "chapterTotalNum": 2451,
                    "imgUrl": "https://img/34078.jpg",
                    "lastChapter": { "chapterName": "第2451章 山边小村" }
                }
            }
        }))
    })
    .await;

    let dir = TempDir::new("shuqi-book");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_book").expect("route registered");
    let params = Params::from_pairs(vec![("book_id".to_string(), "34078".to_string())]);
    let value = handler(&srv.ctx, &params).await.expect("book");

    let rec = upstream.last_request().expect("upstream call");
    assert_eq!(rec.path, "/sqan/sqapi/bff/api/v1/reader/titlepage");

    let b = &value["data"];
    assert_eq!(b["bookId"], "34078");
    assert_eq!(b["name"], "凡人修仙传");
    assert_eq!(b["author"], "忘语");
    assert_eq!(b["status"], "完结");
    assert_eq!(b["chapterTotalNum"], 2451);
    assert_eq!(b["lastChapter"], "第2451章 山边小村");
    assert_eq!(b["tocUrl"], "/sqtoc/34078");
    let kind = b["kind"].as_str().unwrap_or("");
    assert!(kind.contains("玄幻"), "{kind}");
    assert!(kind.contains("修仙"), "{kind}");
    assert!(kind.contains("9.2分"), "{kind}");
    assert_eq!(b["wordCount"], "2451万字");
}

#[tokio::test]
async fn book_id_can_come_from_internal_url() {
    let upstream = MockUpstream::start(|_: &Recorded| {
        MockReply::json(json!({ "data": { "bookInfo": { "bookId": 7, "bookName": "x" } } }))
    })
    .await;
    let dir = TempDir::new("shuqi-book-url");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_book").expect("route registered");
    let params = Params::from_pairs(vec![("book_id".to_string(), "/sqbook/7".to_string())]);
    let value = handler(&srv.ctx, &params).await.expect("book");
    assert_eq!(value["data"]["bookId"], "7");
}

// --- 目录 ------------------------------------------------------------------

#[tokio::test]
async fn toc_uses_h5_and_strips_vip_tags_and_ordinals() {
    let html = r#"<html><body>
<a href="/reader?bid=34078&amp;cid=2180322">1.第1章 山边小村</a>
<a href="/reader?bid=34078&amp;cid=2180323">2.第2章 惊变<i class="vip-tag">VIP</i></a>
<a href="/reader?bid=34078&amp;cid=2180322">1.第1章 山边小村</a>
</body></html>"#;
    let upstream = MockUpstream::start(move |_: &Recorded| text(html)).await;

    let dir = TempDir::new("shuqi-toc-h5");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_toc").expect("route registered");
    let params = Params::from_pairs(vec![("book_id".to_string(), "34078".to_string())]);
    let value = handler(&srv.ctx, &params).await.expect("toc");

    let rec = upstream.last_request().expect("upstream call");
    assert_eq!(rec.path, "/chapter");
    assert_eq!(rec.query, "bid=34078");

    let data = &value["data"];
    assert_eq!(data["path"], "h5");
    let chapters = data["chapters"].as_array().expect("chapters");
    assert_eq!(chapters.len(), 2, "duplicate cid must collapse");
    assert_eq!(chapters[0]["title"], "第1章 山边小村");
    assert_eq!(chapters[0]["url"], "/sqch/34078/2180322");
    assert_eq!(chapters[0]["isVip"], false);
    // VIP 标签必须整体删掉，不能混进章名
    assert_eq!(chapters[1]["title"], "第2章 惊变");
    assert_eq!(chapters[1]["isVip"], true);
}

#[tokio::test]
async fn toc_falls_back_to_index_when_h5_has_no_chapters() {
    let upstream = MockUpstream::start(|rec: &Recorded| match rec.path.as_str() {
        "/chapter" => text("<html><body>维护中，没有章节</body></html>"),
        "/sqan/sqapi/bff/api/v1/reader/chapterinfo" => MockReply::json(json!({
            "data": { "chapter": { "chapterId": 2180322, "name": "第1章 山边小村" } }
        })),
        "/sqan/sqapi/bff/api/v1/reader/titlepage" => MockReply::json(json!({
            "data": { "bookInfo": { "chapterTotalNum": 3 } }
        })),
        _ => MockReply::status(404),
    })
    .await;

    let dir = TempDir::new("shuqi-toc-index");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_toc").expect("route registered");
    let params = Params::from_pairs(vec![("book_id".to_string(), "34078".to_string())]);
    let value = handler(&srv.ctx, &params).await.expect("toc");

    let data = &value["data"];
    assert_eq!(data["path"], "index");
    assert_eq!(data["total"], 3);
    let chapters = data["chapters"].as_array().expect("chapters");
    assert_eq!(chapters.len(), 3);
    // 首章用服务端真名，其余是占位；chapterId 严格 +1 递推
    assert_eq!(chapters[0]["title"], "第1章 山边小村");
    assert_eq!(chapters[0]["url"], "/sqch/34078/2180322");
    assert_eq!(chapters[1]["title"], "第2章");
    assert_eq!(chapters[1]["url"], "/sqch/34078/2180323");
    assert_eq!(chapters[2]["url"], "/sqch/34078/2180324");
}

#[tokio::test]
async fn toc_index_rejects_an_absurd_chapter_total() {
    let upstream = MockUpstream::start(|rec: &Recorded| match rec.path.as_str() {
        "/chapter" => text("<html><body>维护中，没有章节</body></html>"),
        "/sqan/sqapi/bff/api/v1/reader/chapterinfo" => MockReply::json(json!({
            "data": { "chapter": { "chapterId": 2180322, "name": "第1章" } }
        })),
        "/sqan/sqapi/bff/api/v1/reader/titlepage" => MockReply::json(json!({
            "data": { "bookInfo": { "chapterTotalNum": 9_999_999 } }
        })),
        _ => MockReply::status(404),
    })
    .await;

    let dir = TempDir::new("shuqi-toc-cap");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_toc").expect("route registered");
    let params = Params::from_pairs(vec![("book_id".to_string(), "34078".to_string())]);
    let err = handler(&srv.ctx, &params)
        .await
        .expect_err("absurd chapter total must be rejected instead of materialized");
    assert!(err.message().contains("chapter cap"), "{}", err.message());
}

#[tokio::test]
async fn toc_h5_rejects_more_than_the_chapter_cap() {
    let mut html = String::from("<html><body>");
    for i in 0..20_001 {
        html.push_str(&format!(
            r#"<a href="/reader?bid=34078&amp;cid={}">第{i}章</a>"#,
            100_000 + i
        ));
    }
    html.push_str("</body></html>");
    let upstream = MockUpstream::start(move |_: &Recorded| text(&html)).await;

    let dir = TempDir::new("shuqi-toc-h5-cap");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_toc").expect("route registered");
    let params = Params::from_pairs(vec![("book_id".to_string(), "34078".to_string())]);
    let err = handler(&srv.ctx, &params)
        .await
        .expect_err("an oversized h5 toc must be rejected instead of materialized");
    assert!(err.message().contains("chapter cap"), "{}", err.message());
}

// --- 正文 ------------------------------------------------------------------

#[tokio::test]
async fn chapter_prefers_cdn_plaintext() {
    let upstream = MockUpstream::start(|rec: &Recorded| {
        if rec.path.starts_with("/httpserver/filecache/") {
            text(r#"cb([{"content":"第一段<br/>第二段&nbsp;结束"}])"#)
        } else {
            MockReply::status(404)
        }
    })
    .await;

    let dir = TempDir::new("shuqi-chapter-cdn");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_chapter").expect("route registered");
    let params = Params::from_pairs(vec![
        ("book_id".to_string(), "34078".to_string()),
        ("chapter_id".to_string(), "2180322".to_string()),
    ]);
    let value = handler(&srv.ctx, &params).await.expect("chapter");

    let data = &value["data"];
    assert_eq!(data["path"], "cdn");
    assert_eq!(data["content"], "第一段\n第二段 结束");
    let rec = upstream.last_request().expect("upstream call");
    assert!(
        rec.path.contains("get_book_content_34078_2180322_"),
        "unexpected cdn path: {}",
        rec.path
    );
}

#[tokio::test]
async fn chapter_falls_back_to_chapterinfo_and_decodes() {
    // chapterinfo 的正文是 rot13(base64(text))，再用 <br> 表示换行。
    let plain = "正文第一段<br/>正文第二段";
    let encoded = fqapi_core::upstream::shuqi::rot13(&STANDARD.encode(plain));

    let upstream = MockUpstream::start(move |rec: &Recorded| {
        if rec.path.starts_with("/httpserver/filecache/") {
            // 两轮 CDN（http 与 https）都打空，逼出 chapterinfo 兜底
            MockReply::status(404)
        } else if rec.path.ends_with("/reader/chapterinfo") {
            MockReply::json(json!({
                "data": { "chapter": { "content": encoded } }
            }))
        } else {
            MockReply::status(404)
        }
    })
    .await;

    let dir = TempDir::new("shuqi-chapter-fallback");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_chapter").expect("route registered");
    let params = Params::from_pairs(vec![
        ("book_id".to_string(), "34078".to_string()),
        ("chapter_id".to_string(), "2180322".to_string()),
    ]);
    let value = handler(&srv.ctx, &params).await.expect("chapter");

    let data = &value["data"];
    assert_eq!(data["path"], "chapterinfo");
    assert_eq!(data["content"], "正文第一段\n正文第二段");
}

#[tokio::test]
async fn chapter_error_reports_the_failed_cdn_attempts() {
    let upstream = MockUpstream::start(|rec: &Recorded| {
        if rec.path.starts_with("/httpserver/filecache/") {
            // CDN 打空，chapterinfo 也没给正文：最终错误要带上 CDN 的原因。
            MockReply::status(404)
        } else if rec.path.ends_with("/reader/chapterinfo") {
            MockReply::json(json!({ "data": { "chapter": {} } }))
        } else {
            MockReply::status(404)
        }
    })
    .await;

    let dir = TempDir::new("shuqi-chapter-cdn-errors");
    let srv = server(&dir, &upstream.origin).await;
    let handler = srv.handler("shuqi_chapter").expect("route registered");
    let params = Params::from_pairs(vec![
        ("book_id".to_string(), "34078".to_string()),
        ("chapter_id".to_string(), "2180322".to_string()),
    ]);
    let err = handler(&srv.ctx, &params)
        .await
        .expect_err("no content on any leg");
    let message = err.message();
    assert!(message.contains("cdn attempts"), "{message}");
    assert!(message.contains("get_book_content_"), "{message}");

    // http 与 https 两轮、每轮 2 host × 2 flag 的探测都必须跑过。
    let cdn_calls = upstream
        .requests()
        .iter()
        .filter(|rec| rec.path.starts_with("/httpserver/filecache/"))
        .count();
    assert_eq!(cdn_calls, 8, "every host/flag/scheme must be tried");
}
