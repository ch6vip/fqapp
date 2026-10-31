//! 书旗接口的公共取值、参数解析与上游调用。

use regex::Regex;
use serde_json::{Map, Value};
use std::sync::OnceLock;

use crate::endpoints::base::{Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};
use crate::upstream::shuqi as proto;

/// 内部详情/目录地址里的 bookId：`/sqbook/34078`、`/sqtoc/34078`。
fn internal_book_url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/sq(?:book|toc)/(\d+)").expect("book url regex"))
}

/// query 里的 bookId（`?bookId=34078`）。
fn book_id_query_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[?&]bookId=(\d+)").expect("book id query regex"))
}

/// 内部正文地址 `/sqch/<bookId>/<chapterId>`。
fn internal_chapter_url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/sqch/(\d+)/(\d+)").expect("chapter url regex"))
}

pub(super) fn pick(params: &Params, names: &[&str]) -> String {
    for n in names {
        let v = params.get_str(n);
        if !v.is_empty() {
            return v;
        }
    }
    String::new()
}

/// 从内部地址（`/sqbook/<id>`、`/sqtoc/<id>`）或 query 里取 bookId。
pub(super) fn resolve_book_id(params: &Params) -> ApiResult<String> {
    let raw = pick(params, &["book_id", "bookId", "bid", "url"]);
    if raw.is_empty() {
        return Err(ApiError::BadRequest("missing book_id parameter".into()));
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return Ok(raw);
    }
    if let Some(caps) = internal_book_url_regex().captures(&raw) {
        return Ok(caps[1].to_string());
    }
    if let Some(caps) = book_id_query_regex().captures(&raw) {
        return Ok(caps[1].to_string());
    }
    Err(ApiError::BadRequest(format!(
        "cannot resolve book_id from {raw}"
    )))
}

pub(super) fn resolve_chapter_id(params: &Params) -> ApiResult<String> {
    let raw = pick(params, &["chapter_id", "chapterId", "cid", "url"]);
    if raw.is_empty() {
        return Err(ApiError::BadRequest("missing chapter_id parameter".into()));
    }
    if raw.chars().all(|c| c.is_ascii_digit()) {
        return Ok(raw);
    }
    if let Some(caps) = internal_chapter_url_regex().captures(&raw) {
        return Ok(caps[2].to_string());
    }
    Err(ApiError::BadRequest(format!(
        "cannot resolve chapter_id from {raw}"
    )))
}

/// 加密口 POST：构造签名体，发出去，返回解析后的 JSON。
pub(super) async fn post_enc(
    ctx: &Ctx,
    path: &str,
    biz: &[(&str, &str)],
    uid: Option<&str>,
) -> ApiResult<Value> {
    let req = proto::app_body(biz, uid, None).map_err(ApiError::Internal)?;
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::NoSign,
        method: Some("POST".to_string()),
        raw_url: Some(format!("{}{}", proto::HOST, path)),
        body: Some(req.body.into_bytes()),
        headers: req.headers,
        ..Default::default()
    };
    let raw = Upstream::new(ctx.up.clone()).raw(&spec).await?;
    crate::endpoints::util::raw_json(&raw)
}

/// 免签 GET，返回文本。`NoSign` 下上游层不注入任何番茄签名。
pub(super) async fn get_text(
    ctx: &Ctx,
    url: &str,
    headers: Vec<(String, String)>,
) -> ApiResult<String> {
    let spec = UpstreamRequestSpec {
        mode: UpstreamMode::NoSign,
        method: Some("GET".to_string()),
        raw_url: Some(url.to_string()),
        headers,
        ..Default::default()
    };
    let raw = Upstream::new(ctx.up.clone()).raw(&spec).await?;
    Ok(String::from_utf8_lossy(&raw).into_owned())
}

pub(super) fn browser_headers() -> Vec<(String, String)> {
    vec![("User-Agent".to_string(), proto::UA.to_string())]
}

pub(super) fn text_of(m: &Map<String, Value>, keys: &[&str]) -> String {
    for k in keys {
        match m.get(*k) {
            Some(Value::String(s)) => return s.clone(),
            Some(Value::Number(n)) => return n.to_string(),
            Some(Value::Bool(b)) => return b.to_string(),
            _ => {}
        }
    }
    String::new()
}

pub(super) fn as_i64(v: Option<&Value>) -> i64 {
    match v {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

fn whitespace_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").expect("whitespace regex"))
}

/// `sqPlain`：去标签 + 压缩空白。
pub(super) fn plain(s: &str) -> String {
    whitespace_regex()
        .replace_all(&proto::strip_tags(s), " ")
        .trim()
        .to_string()
}

/// `sqWan`：字数归一化。
pub(super) fn wan(v: Option<&Value>) -> String {
    let n = match v {
        Some(Value::Number(x)) => x.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.parse().unwrap_or(0.0),
        _ => 0.0,
    };
    if n >= 100_000_000.0 {
        format!("{}亿字", (n / 1_000_000.0).round() / 100.0)
    } else if n >= 10_000.0 {
        format!("{}万字", (n / 1_000.0).round() / 10.0)
    } else if n > 0.0 {
        format!("{}字", n as i64)
    } else {
        String::new()
    }
}

/// `sqStatus`：只有 `"2"` 是完结。
pub(super) fn status_of(m: &Map<String, Value>) -> String {
    let raw = text_of(m, &["serialState", "state", "bookStatus"]);
    if raw.is_empty() {
        return String::new();
    }
    if raw == "2" {
        "完结".to_string()
    } else {
        "连载".to_string()
    }
}

/// 标签数组 → 逗号串。元素可以是字符串，也可以是带 `tagName` 的对象。
pub(super) fn tag_str(m: &Map<String, Value>) -> String {
    let list = m
        .get("tagList")
        .or_else(|| m.get("tags"))
        .or_else(|| m.get("tag"));
    let arr = match list {
        Some(Value::Array(a)) => a.clone(),
        _ => return String::new(),
    };
    arr.iter()
        .map(|t| match t {
            Value::String(s) => plain(s),
            Value::Object(o) => plain(&text_of(o, &["tagName", "name"])),
            _ => String::new(),
        })
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(",")
}
