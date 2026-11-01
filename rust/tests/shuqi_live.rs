//! 书旗真实上游冒烟测试。
//!
//! 默认不跑（`#[ignore]`），只在联调时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test shuqi_live -- --ignored --nocapture
//! ```
//!
//! 离线契约测试只能证明「实现与源脚本一致」；这条链路验证的是另一半：
//! 服务端是否真的接受我们算出来的 `sign` / `x-sq-public` / `data`。

mod common;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;

#[tokio::test]
#[ignore = "hits the live shuqi upstream"]
async fn live_search_then_titlepage() {
    let dir = TempDir::new("shuqi-live");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    let search = srv.handler("shuqi_search").expect("route");
    let params = Params::from_pairs(vec![("key".to_string(), "凡人修仙传".to_string())]);
    let value = search(&srv.ctx, &params)
        .await
        .expect("live search must succeed");
    let list = value["data"].as_array().expect("list");
    println!("search returned {} books", list.len());
    for item in list.iter().take(3) {
        println!(
            "  - id={} name={} author={}",
            item["bookId"], item["name"], item["author"]
        );
    }
    let book_id = list[0]["bookId"].as_str().expect("bookId").to_string();

    let detail = srv.handler("shuqi_book").expect("route");
    let params = Params::from_pairs(vec![("book_id".to_string(), book_id.clone())]);
    let value = detail(&srv.ctx, &params)
        .await
        .expect("live titlepage must succeed");
    let data = &value["data"];
    println!(
        "titlepage: name={} total={} status={}",
        data["name"], data["chapterTotalNum"], data["status"]
    );
    assert!(
        data["chapterTotalNum"].as_i64().unwrap_or(0) > 0,
        "chapterTotalNum must be populated"
    );
}

#[tokio::test]
#[ignore = "hits the live shuqi upstream"]
async fn live_toc_then_chapter() {
    let dir = TempDir::new("shuqi-live-toc");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    // 34078 = 凡人修仙传，源文件注释里实测过整本目录。
    let book_id = "34078".to_string();

    let toc = srv.handler("shuqi_toc").expect("route");
    let params = Params::from_pairs(vec![("book_id".to_string(), book_id.clone())]);
    let value = toc(&srv.ctx, &params).await.expect("live toc must succeed");
    let data = &value["data"];
    let chapters = data["chapters"].as_array().expect("chapters");
    println!(
        "toc path={} total={} first={}",
        data["path"], data["total"], chapters[0]["title"]
    );
    assert!(!chapters.is_empty(), "toc must not be empty");

    let chapter_id = chapters[0]["chapterId"].as_str().unwrap_or("").to_string();
    let chapter = srv.handler("shuqi_chapter").expect("route");
    let params = Params::from_pairs(vec![
        ("book_id".to_string(), book_id),
        ("chapter_id".to_string(), chapter_id),
    ]);
    let value = chapter(&srv.ctx, &params)
        .await
        .expect("live chapter must succeed");
    let text = value["data"]["content"].as_str().unwrap_or("");
    println!(
        "chapter path={} chars={}",
        value["data"]["path"],
        text.chars().count()
    );
    println!("  preview: {}", text.chars().take(80).collect::<String>());
    assert!(
        text.chars().count() > 50,
        "chapter body looks too short: {text}"
    );
}
