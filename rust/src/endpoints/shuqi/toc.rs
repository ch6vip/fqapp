//! 书旗目录：H5 全量页主路 + `chapterinfo` 递推回退。

use std::collections::HashSet;
use std::sync::OnceLock;

use futures::future::BoxFuture;
use regex::Regex;
use serde_json::{json, Value};

use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::shuqi as proto;

use super::common::{as_i64, browser_headers, get_text, plain, post_enc, resolve_book_id};

/// 目录递推的章数上限：`chapterTotalNum` 完全来自上游，异常值不能直接变成
/// 一个巨型数组。真实长篇到两万章已经极端。
const MAX_TOC_CHAPTERS: i64 = 20_000;

/// 目录 H5 页里每条章节的锚点。`(?s)` 让 `.` 跨行，`(?:amp;)?` 兼容转义过的 `&`。
fn toc_anchor_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r#"(?is)href="/reader\?bid=(\d+)&(?:amp;)?cid=(\d+)"[^>]*>(.*?)</a>"#)
            .expect("toc anchor regex")
    })
}

/// 章节标题里的 `<i class="vip-tag">VIP</i>` 必须整体删掉，否则 "VIP" 会混进章名。
fn toc_inline_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?is)<i[^>]*>.*?</i>").expect("inline tag regex"))
}

fn any_tag_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"<[^>]*>").expect("any tag regex"))
}

fn whitespace_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").expect("whitespace regex"))
}

/// 章名前的 "1001." / "1001、" 序号前缀。
fn ordinal_prefix_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\d+[.、]\s*").expect("ordinal regex"))
}

/// 主路：H5 全量目录页，一次拿到整本与真章名。传输/解析不可用时返回 None，
/// 交给递推腿；章数超过上限则直接报错——异常页不该被当成正常目录。
async fn toc_from_h5(ctx: &Ctx, bid: &str) -> ApiResult<Option<Vec<Value>>> {
    let url = proto::toc_h5_url(bid);
    let html = match get_text(ctx, &url, browser_headers()).await {
        Ok(t) => t,
        // 这条路不可用时返回 None，交给递推腿，不把错误抛给调用方。
        Err(_) => return Ok(None),
    };
    if !html.contains("cid=") {
        return Ok(None);
    }

    let mut rows: Vec<Value> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for caps in toc_anchor_regex().captures_iter(&html) {
        let cid = caps[2].to_string();
        if !seen.insert(cid.clone()) {
            continue;
        }
        let anchor = caps.get(0).map(|m| m.as_str()).unwrap_or("");
        let inner = toc_inline_tag_regex().replace_all(&caps[3], " ");
        let inner = any_tag_regex().replace_all(&inner, " ");
        let inner = inner
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">");
        let inner = whitespace_regex()
            .replace_all(&inner, " ")
            .trim()
            .to_string();
        let title = ordinal_prefix_regex()
            .replace(&inner, "")
            .trim()
            .to_string();
        if title.is_empty() {
            continue;
        }
        let is_vip = anchor.contains("vip-tag") || anchor.contains("VIP");
        rows.push(json!({
            "title": title,
            "url": format!("/sqch/{bid}/{cid}"),
            "chapterId": cid,
            "isVip": is_vip,
            "isPay": is_vip,
        }));
        // H5 页同样是上游数据：和递推路径共用同一个上限，且一旦越界就停，
        // 不把异常页整份展开成数组。
        if rows.len() > MAX_TOC_CHAPTERS as usize {
            return Err(ApiError::Internal(format!(
                "shuqi toc h5 for book {bid} exceeds the {MAX_TOC_CHAPTERS} chapter cap"
            )));
        }
    }

    if rows.is_empty() {
        Ok(None)
    } else {
        Ok(Some(rows))
    }
}

/// 回退：`chapterinfo` 拿首章 id + `titlepage` 拿总章数，靠「章内 id 严格 +1 连续」递推。
///
/// 章名只能给占位。源脚本在总章数拿不到时会兜底成 1 章，那会静默截断整本目录，
/// 这里改为直接报错。
async fn toc_by_index(ctx: &Ctx, bid: &str) -> ApiResult<Value> {
    let first = post_enc(
        ctx,
        proto::path::CHAPTERINFO,
        &[("bookId", bid)],
        Some(proto::CI_UID),
    )
    .await?;
    let chapter = first.get("data").and_then(|d| d.get("chapter"));
    let base = as_i64(chapter.and_then(|c| c.get("chapterId")));
    if base == 0 {
        return Err(ApiError::Internal(format!(
            "shuqi toc probe found no first chapter for book {bid}"
        )));
    }
    let first_name = chapter
        .and_then(|c| c.get("name"))
        .and_then(|n| n.as_str())
        .map(plain)
        .unwrap_or_default();

    let info = post_enc(ctx, proto::path::TITLEPAGE, &[("bookId", bid)], None).await?;
    let total = {
        let from_book = info
            .get("data")
            .and_then(|d| d.get("bookInfo"))
            .map(|b| as_i64(b.get("chapterTotalNum")))
            .unwrap_or(0);
        if from_book > 0 {
            from_book
        } else {
            info.get("data")
                .map(|d| as_i64(d.get("chapterTotalNum")))
                .unwrap_or(0)
        }
    };
    if total <= 0 {
        return Err(ApiError::Internal(format!(
            "shuqi toc total chapter count missing for book {bid}"
        )));
    }
    if total > MAX_TOC_CHAPTERS {
        return Err(ApiError::Internal(format!(
            "shuqi toc total {total} for book {bid} exceeds the {MAX_TOC_CHAPTERS} chapter cap"
        )));
    }

    let rows: Vec<Value> = (0..total)
        .map(|i| {
            let cid = base + i;
            let title = if i == 0 {
                if first_name.is_empty() {
                    "第1章".to_string()
                } else {
                    first_name.clone()
                }
            } else {
                format!("第{}章", i + 1)
            };
            json!({
                "title": title,
                "url": format!("/sqch/{bid}/{cid}"),
                "chapterId": cid.to_string(),
                "isVip": false,
                "isPay": false,
            })
        })
        .collect();

    Ok(json!({
        "source": "shuqi",
        "data": { "path": "index", "total": total, "chapters": rows }
    }))
}

pub(super) fn handle_toc<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let bid = resolve_book_id(params)?;
        if let Some(rows) = toc_from_h5(ctx, &bid).await? {
            let total = rows.len();
            return Ok(json!({
                "source": "shuqi",
                "data": { "path": "h5", "total": total, "chapters": rows }
            }));
        }
        toc_by_index(ctx, &bid).await
    })
}
