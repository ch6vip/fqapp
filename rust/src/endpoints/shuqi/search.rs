//! 书旗搜索：加密口搜索 + 递归收集书节点。

use std::collections::HashSet;

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::shuqi as proto;

use super::common::{pick, plain, post_enc, status_of, tag_str, text_of, wan};

fn search_item(m: &Map<String, Value>, bid: &str, name: &str) -> Value {
    let mut kind: Vec<String> = Vec::new();
    let cat = plain(&text_of(
        m,
        &["categoryName", "category", "first_category_name"],
    ));
    if !cat.is_empty() {
        kind.push(cat);
    }
    let tags = tag_str(m);
    if !tags.is_empty() {
        kind.push(tags);
    }
    let last_chapter = {
        let direct = plain(&text_of(m, &["latestChapterName", "lastChapter"]));
        if !direct.is_empty() {
            direct
        } else {
            m.get("latest_chapter")
                .and_then(|c| c.get("cname"))
                .and_then(|c| c.as_str())
                .map(plain)
                .unwrap_or_default()
        }
    };

    json!({
        "bookId": bid,
        "name": plain(name),
        "author": plain(&text_of(m, &["authorName", "author"])),
        "bookUrl": format!("/sqbook/{bid}"),
        "coverUrl": text_of(m, &["imgUrl", "cover", "coverUrl"]),
        "intro": plain(&text_of(m, &["briefIntro", "intro", "desc", "recommendReason"])),
        "wordCount": wan(m.get("wordCount").or_else(|| m.get("words"))),
        "status": status_of(m),
        "lastChapter": last_chapter,
        "kind": kind.join(","),
        "source": "shuqi",
    })
}

/// 递归收集书节点：模块里的 filter/标签项也带 id+title，所以判据要更严
/// （`bookId|id|bid` + `书名` + 任一「像书」的字段）。
fn walk(v: &Value, depth: usize, out: &mut Vec<Value>) {
    if depth > 8 {
        return;
    }
    match v {
        Value::Array(items) => {
            for it in items {
                walk(it, depth + 1, out);
            }
        }
        Value::Object(m) => {
            let bid = text_of(m, &["bookId", "id", "bid"]);
            let name = text_of(m, &["bookName", "title"]);
            let bookish = m.contains_key("desc")
                || m.contains_key("tags")
                || m.contains_key("tagList")
                || !text_of(
                    m,
                    &[
                        "authorName",
                        "author",
                        "imgUrl",
                        "cover",
                        "coverUrl",
                        "wordCount",
                        "briefIntro",
                    ],
                )
                .is_empty();
            if !bid.is_empty() && !name.is_empty() && bookish {
                out.push(search_item(m, &bid, &name));
            } else {
                for (_, child) in m {
                    walk(child, depth + 1, out);
                }
            }
        }
        _ => {}
    }
}

pub(super) fn handle_search<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let key = pick(params, &["key", "query", "q", "keyword"]);
        if key.is_empty() {
            return Err(ApiError::BadRequest("missing key parameter".into()));
        }
        let ts = proto::now_ms();
        // 注意：`page` 是模块名常量，不是页码 —— 书旗搜索不支持分页。
        let payload = post_enc(
            ctx,
            proto::path::SEARCH,
            &[
                ("page", "searchResultV3"),
                ("query", key.as_str()),
                ("timestamp", ts.as_str()),
            ],
            None,
        )
        .await?;

        let root = payload.get("data").cloned().unwrap_or(payload.clone());
        let mut found: Vec<Value> = Vec::new();
        walk(&root, 0, &mut found);

        let mut seen: HashSet<String> = HashSet::new();
        let mut uniq: Vec<Value> = Vec::new();
        for item in found {
            let name = item.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let author = item.get("author").and_then(|v| v.as_str()).unwrap_or("");
            let k = format!("{name}|{author}");
            if !seen.insert(k) {
                continue;
            }
            uniq.push(item);
        }

        if uniq.is_empty() {
            let msg = payload
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("empty result");
            return Err(ApiError::Internal(format!(
                "shuqi search returned no books: {msg}"
            )));
        }

        Ok(json!({ "source": "shuqi", "data": uniq }))
    })
}
