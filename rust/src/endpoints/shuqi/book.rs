//! 书旗书籍详情（titlepage）。

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::shuqi as proto;

use super::common::{as_i64, plain, post_enc, resolve_book_id, status_of, tag_str, text_of, wan};

fn book_score(b: &Map<String, Value>) -> String {
    let direct = text_of(b, &["score"]);
    if !direct.is_empty() {
        return direct;
    }
    b.get("scoreInfo")
        .map(|s| text_of(s.as_object().unwrap_or(&Map::new()), &["bookScore"]))
        .unwrap_or_default()
}

fn book_kind(b: &Map<String, Value>) -> String {
    let mut kind: Vec<String> = Vec::new();
    let class = plain(&text_of(b, &["className"]));
    if !class.is_empty() {
        kind.push(class);
    }
    let tags = tag_str(b);
    if !tags.is_empty() {
        kind.push(tags);
    }
    let status = status_of(b);
    if !status.is_empty() {
        kind.push(status);
    }
    let score = book_score(b);
    if !score.is_empty() {
        kind.push(format!("{score}分"));
    }
    kind.join(",")
}

fn book_last_chapter(b: &Map<String, Value>) -> String {
    let direct = text_of(b, &["latestChapterName", "finalChapterName"]);
    if !direct.is_empty() {
        return plain(&direct);
    }
    b.get("lastChapter")
        .or_else(|| b.get("latestChapter"))
        .or_else(|| b.get("firstChapter"))
        .and_then(|c| c.get("chapterName"))
        .and_then(|c| c.as_str())
        .map(plain)
        .unwrap_or_default()
}

pub(super) fn handle_book<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let bid = resolve_book_id(params)?;
        let payload = post_enc(
            ctx,
            proto::path::TITLEPAGE,
            &[("bookId", bid.as_str())],
            None,
        )
        .await?;

        let b = match payload.get("data").and_then(|d| d.get("bookInfo")) {
            Some(Value::Object(m)) if !m.is_empty() => m.clone(),
            _ => {
                let msg = payload
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("empty bookInfo");
                return Err(ApiError::Internal(format!(
                    "shuqi titlepage empty for book {bid}: {msg}"
                )));
            }
        };

        let status = status_of(&b);
        let total = as_i64(b.get("chapterTotalNum"));

        Ok(json!({
            "source": "shuqi",
            "data": {
                "bookId": b.get("bookId").map(|v| v.to_string().trim_matches('"').to_string()).unwrap_or_else(|| bid.clone()),
                "name": plain(&text_of(&b, &["bookName", "title"])),
                "author": plain(&text_of(&b, &["authorName", "author"])),
                "intro": plain(&text_of(&b, &["desc", "briefIntro", "intro", "recIntro"])),
                "kind": book_kind(&b),
                "coverUrl": text_of(&b, &["imgUrl", "coverUrl", "cover"]),
                "wordCount": wan(b.get("wordCount")),
                "lastChapter": book_last_chapter(&b),
                "status": status,
                "chapterTotalNum": total,
                "bookUrl": format!("/sqbook/{bid}"),
                "tocUrl": format!("/sqtoc/{bid}"),
            }
        }))
    })
}
