//! The `/api/*` Web bridge shared by the built-in Web UI.

use serde_json::{json, Map, Value};

use crate::dispatch::Response;
use crate::endpoints::{Params, Server};
use crate::json::{as_map, extract_upstream_data, strip_html_tags, web_err, web_ok};
use crate::sign::query_param;

const FANQIE_BOOK_PAGE_URL_FORMAT: &str = "https://fanqienovel.com/page/%s";

async fn call_endpoint(server: &Server, name: &str, params: &Params) -> Result<Value, String> {
    let handler = server
        .handler(name)
        .ok_or_else(|| format!("endpoint {name:?} not registered"))?;
    handler(&server.ctx, params)
        .await
        .map_err(|e| e.message().to_string())
}

fn web_json(status: u16, value: &Value) -> Response {
    Response::json(status, value)
}

/// `webUpstreamFailed`: HTTP 200 can still carry a business failure.
fn web_upstream_failed(result: &Value) -> bool {
    let Some(m) = as_map(result) else {
        return false;
    };
    match m.get("code").and_then(|c| c.as_f64()) {
        Some(code) => code != 0.0 && code != 200.0,
        None => false,
    }
}

fn write_web_upstream_result(result: &Value, transform: Option<fn(&Value) -> Value>) -> Response {
    if web_upstream_failed(result) {
        return web_json(200, result);
    }
    let mut data = extract_upstream_data(result);
    if let Some(f) = transform {
        data = f(&data);
    }
    web_json(200, &web_ok(data))
}

pub async fn handle(server: &Server, path: &str, q: &Params) -> Response {
    let action = path
        .trim_start_matches("/api/")
        .split('/')
        .next()
        .unwrap_or("")
        .to_string();
    // The dispatcher passes only the query; recover the action from __path__.
    match action.as_str() {
        "search" => handle_web_search(server, q).await,
        "detail" => handle_web_detail(server, q).await,
        "directory" => handle_web_directory(server, q).await,
        "content" => handle_web_content(server, q).await,
        "resolve" => handle_web_resolve(server, q).await,
        "download" => handle_web_download(server, q).await,
        other => web_json(404, &web_err(404, &format!("unknown api: {other}"))),
    }
}

// --- Search ---
async fn handle_web_search(server: &Server, q: &Params) -> Response {
    let source = q.get_str("source");
    let query = q.get_str("query");
    if source != "番茄" || query.is_empty() {
        return web_json(400, &web_err(400, "需要 source=番茄 和 query"));
    }
    let mut page = crate::endpoints::util::int_default(&q.get_str("page"), 1);
    if page < 1 {
        page = 1;
    }
    let offset = ((page - 1) * 9).to_string();

    let mut params = Params::new();
    params.set("query", query);
    params.set("offset", offset);

    match call_endpoint(server, "search", &params).await {
        Ok(result) => write_web_upstream_result(&result, Some(normalize_search_tabs)),
        Err(e) => web_json(500, &web_err(500, &e)),
    }
}

/// Copies the "综合" tab data into individual content tabs.
fn normalize_search_tabs(data: &Value) -> Value {
    let Some(m) = as_map(data) else {
        return data.clone();
    };
    let Some(tabs) = m.get("search_tabs").and_then(|t| t.as_array()) else {
        return data.clone();
    };

    let mut comprehensive: Vec<Value> = Vec::new();
    for t in tabs {
        if let Some(tab) = as_map(t) {
            if tab.get("title").and_then(|v| v.as_str()) == Some("综合") {
                if let Some(d) = tab.get("data").and_then(|v| v.as_array()) {
                    comprehensive = d.clone();
                }
                break;
            }
        }
    }
    if comprehensive.is_empty() {
        return data.clone();
    }

    let mut out = data.clone();
    if let Some(obj) = out.as_object_mut() {
        if let Some(tabs_mut) = obj.get_mut("search_tabs").and_then(|t| t.as_array_mut()) {
            for t in tabs_mut.iter_mut() {
                let Some(tab) = t.as_object_mut() else {
                    continue;
                };
                let title = tab
                    .get("title")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if !matches!(title.as_str(), "书籍" | "漫画" | "听书" | "短剧") {
                    continue;
                }
                let existing_len = tab
                    .get("data")
                    .and_then(|v| v.as_array())
                    .map(|a| a.len())
                    .unwrap_or(0);
                if existing_len > 0 {
                    continue;
                }
                tab.insert("data".to_string(), Value::Array(comprehensive.clone()));
            }
        }
    }
    out
}

// --- Detail ---
async fn handle_web_detail(server: &Server, q: &Params) -> Response {
    let source = q.get_str("source");
    let book_id = q.get_str("book_id");
    let tab = q.get_str("tab");
    if source != "番茄" || book_id.is_empty() {
        return web_json(400, &web_err(400, "需要 source=番茄 和 book_id"));
    }
    let (ep_name, params) = match tab.as_str() {
        "听书" => {
            let mut p = Params::new();
            p.set("book_id", book_id);
            ("audio_book_detail", p)
        }
        _ => {
            let mut p = Params::new();
            p.set("book_id", book_id);
            ("book_detail_legacy", p)
        }
    };
    if server.handler(ep_name).is_none() {
        return web_json(500, &web_err(500, &format!("{ep_name} not available")));
    }
    match call_endpoint(server, ep_name, &params).await {
        Ok(result) => write_web_upstream_result(&result, None),
        Err(e) => web_json(500, &web_err(500, &e)),
    }
}

// --- Directory ---
async fn handle_web_directory(server: &Server, q: &Params) -> Response {
    let source = q.get_str("source");
    let book_id = q.get_str("book_id");
    let tab = q.get_str("tab");
    if source != "番茄" || book_id.is_empty() {
        return web_json(400, &web_err(400, "需要 source=番茄 和 book_id"));
    }

    let result: Result<Value, String>;
    if tab == "短剧" {
        let mut p = Params::new();
        p.set("book_id", book_id.clone());
        let first = call_endpoint(server, "directory", &p).await;
        let needs_fallback = match &first {
            Ok(v) => !series_data_has_episodes(v),
            Err(_) => true,
        };
        if needs_fallback {
            let mut p2 = Params::new();
            p2.set("pseries_id", book_id.clone());
            result = call_endpoint(server, "pseries", &p2).await;
        } else {
            result = first;
        }
    } else {
        let mut p = Params::new();
        p.set("book_id", book_id.clone());
        result = call_endpoint(server, "directory", &p).await;
    }

    match result {
        Ok(v) => {
            if tab == "短剧" {
                write_web_upstream_result(&v, Some(transform_series_data))
            } else {
                write_web_upstream_result(&v, Some(transform_directory_data))
            }
        }
        Err(e) => web_json(500, &web_err(500, &e)),
    }
}

fn series_data_has_episodes(result: &Value) -> bool {
    if let Some(m) = as_map(result) {
        if let Some(code) = m.get("code").and_then(|c| c.as_f64()) {
            if code != 0.0 {
                return false;
            }
        }
    }
    let data = extract_upstream_data(result);
    let raw_episodes = crate::json::find_episode_list(&data, 0);
    if !raw_episodes.is_empty() {
        return true;
    }
    matches!(&data, Value::Array(a) if !a.is_empty())
}

/// Converts `item_list` into the `chapterListWithVolume` shape.
pub fn transform_directory_data(data: &Value) -> Value {
    let Some(m) = as_map(data) else {
        if let Value::Array(item_list) = data {
            let volume_chapters = normalize_directory_entries(item_list);
            if !volume_chapters.is_empty() {
                return json!({
                    "data": { "chapterListWithVolume": [volume_chapters] }
                });
            }
        }
        return data.clone();
    };

    let mut item_list_raw = None;
    for key in ["item_data_list", "lists", "item_list"] {
        if let Some(v) = m.get(key) {
            item_list_raw = Some(v);
            break;
        }
    }
    let Some(Value::Array(item_list)) = item_list_raw else {
        return data.clone();
    };
    if item_list.is_empty() {
        return data.clone();
    }

    let mut volume_chapters = normalize_directory_entries(item_list);
    if let Some(Value::Object(first)) = volume_chapters.first_mut() {
        first
            .entry("volume_name".to_string())
            .or_insert_with(|| Value::from("正文"));
    }

    let mut out = data.clone();
    if let Some(obj) = out.as_object_mut() {
        obj.insert(
            "data".to_string(),
            json!({ "chapterListWithVolume": [Value::Array(volume_chapters)] }),
        );
    }
    out
}

pub fn normalize_directory_entries(item_list: &[Value]) -> Vec<Value> {
    let mut out = Vec::with_capacity(item_list.len());
    for item in item_list {
        let Some(im) = as_map(item) else { continue };
        let mut entry = Map::new();
        let id = first_map_string(im, &["item_id", "itemId", "chapter_id", "id"]);
        if !id.is_empty() {
            entry.insert("itemId".to_string(), Value::from(id));
        }
        let title = first_map_string(im, &["title", "chapter_title", "name", "item_title"]);
        if !title.is_empty() {
            entry.insert("title".to_string(), Value::from(title));
        }
        if let Some(vn) = im.get("volume_name") {
            entry.insert("volume_name".to_string(), vn.clone());
        }
        out.push(Value::Object(entry));
    }
    out
}

/// Normalizes the pseries response used by short dramas.
pub fn transform_series_data(data: &Value) -> Value {
    let Some(m) = as_map(data) else {
        return data.clone();
    };
    let raw_episodes = crate::json::find_episode_list(&Value::Object(m.clone()), 0);
    if raw_episodes.is_empty() {
        return data.clone();
    }

    let mut normalized: Vec<Value> = Vec::with_capacity(raw_episodes.len());
    for (i, raw) in raw_episodes.iter().enumerate() {
        let Some(im) = as_map(raw) else { continue };
        let mut entry = im.clone();
        let mut id = first_map_string(
            im,
            &["item_id", "itemId", "video_id", "vid", "episode_id", "id"],
        );
        if id.is_empty() {
            if let Some(nested) = im.get("video_data").and_then(|v| as_map(v)) {
                id = first_map_string(nested, &["item_id", "itemId", "video_id", "vid", "id"]);
            }
        }
        if !id.is_empty() {
            entry.insert("itemId".to_string(), Value::from(id.clone()));
            entry
                .entry("item_id".to_string())
                .or_insert_with(|| Value::from(id));
        }
        entry.insert("title".to_string(), Value::from(format!("第{}集", i + 1)));
        entry.insert("episode_index".to_string(), Value::from(i as i64));
        normalized.push(Value::Object(entry));
    }
    if normalized.is_empty() {
        return data.clone();
    }

    let mut out = data.clone();
    if let Some(obj) = out.as_object_mut() {
        obj.insert("episodes".to_string(), Value::Array(normalized.clone()));
        obj.insert(
            "data".to_string(),
            json!({
                "chapterListWithVolume": [Value::Array(normalized.clone())],
                "episodes": Value::Array(normalized),
            }),
        );
    }
    out
}

pub fn first_map_string(m: &Map<String, Value>, keys: &[&str]) -> String {
    for key in keys {
        let Some(v) = m.get(*key) else { continue };
        if v.is_null() {
            continue;
        }
        if let Some(s) = v.as_str() {
            let t = s.trim();
            if !t.is_empty() {
                return t.to_string();
            }
            continue;
        }
        if let Some(s) = crate::json::value_to_string(v) {
            if !s.is_empty() {
                return s;
            }
        }
    }
    String::new()
}

// --- Content ---
async fn handle_web_content(server: &Server, q: &Params) -> Response {
    let source = q.get_str("source");
    let item_id = q.get_str("item_id");
    let tab = q.get_str("tab");
    let tone_id = q.get_str("tone_id");
    let mode = q.get_str("mode");
    if source != "番茄" || item_id.is_empty() {
        return web_json(400, &web_err(400, "需要 source=番茄 和 item_id"));
    }

    let result = match tab.as_str() {
        "漫画" => {
            let mut p = Params::new();
            p.set("item_ids", item_id.clone());
            call_endpoint(server, "manga", &p).await
        }
        "听书" => {
            let mut p = Params::new();
            p.set("item_ids", item_id.clone());
            p.set("genre", "0");
            if tone_id.is_empty() {
                p.set("tone_id", "1");
            } else {
                p.set("tone_id", tone_id.clone());
            }
            call_endpoint(server, "wkcontent", &p).await
        }
        // 漫剧与短剧同为 series vid，同一 video_model 选流链路（实测
        // series 7686494169098898456 首集在 video 端点 200 返回 url+key）。
        // 漫剧此前落进下方图文 content 分支，响应没有 video_url，客户端
        // 报「获取播放地址失败」，feed 内嵌播放器无法播放任何漫剧。
        "短剧" | "漫剧" => {
            let mut p = Params::new();
            p.set("video_id", item_id.clone());
            p.set("item_ids", item_id.clone());
            if !mode.is_empty() {
                p.set("mode", mode.clone());
            }
            call_endpoint(server, "video", &p).await
        }
        _ => {
            let mut p = Params::new();
            p.set("item_ids", item_id.clone());
            call_endpoint(server, "content", &p).await
        }
    };

    match result {
        Ok(v) => write_web_upstream_result(&v, None),
        Err(e) => web_json(500, &web_err(500, &e)),
    }
}

// --- Resolve ---
async fn handle_web_resolve(server: &Server, q: &Params) -> Response {
    let raw_url = q.get_str("url");
    if raw_url.is_empty() {
        return web_json(400, &web_err(400, "需要 url"));
    }

    if raw_url.contains("changdunovel.com") {
        if let Ok(parsed) = url::Url::parse(&raw_url) {
            let book_id = query_param(parsed.query().unwrap_or(""), "book_id").unwrap_or_default();
            if !book_id.is_empty() {
                return web_json(
                    200,
                    &web_ok(json!({
                        "redirect_url": FANQIE_BOOK_PAGE_URL_FORMAT.replace("%s", &book_id)
                    })),
                );
            }
        }
    }

    let mut p = Params::new();
    p.set("url", raw_url.clone());
    match call_endpoint(server, "book_share", &p).await {
        Ok(result) => web_json(200, &web_ok(result)),
        Err(_) => web_json(200, &web_ok(json!({ "redirect_url": raw_url }))),
    }
}

// --- Download ---
async fn handle_web_download(server: &Server, q: &Params) -> Response {
    let source = q.get_str("source");
    let book_id = q.get_str("book_id");
    if source != "番茄" || book_id.is_empty() {
        return web_json(400, &web_err(400, "需要 source=番茄 和 book_id"));
    }

    let mut p = Params::new();
    p.set("book_id", book_id.clone());
    let dir_result = match call_endpoint(server, "directory", &p).await {
        Ok(v) => v,
        Err(e) => return web_json(500, &web_err(500, &e)),
    };

    let chapters = extract_chapter_list(&dir_result);
    let mut out = String::new();
    for ch in &chapters {
        let title = ch.get("title").and_then(|v| v.as_str()).unwrap_or("");
        let id = ch.get("id").and_then(|v| v.as_str()).unwrap_or("");
        out.push_str(&format!("# {title}\n"));

        let mut wrote = false;
        if !id.is_empty() {
            let mut cp = Params::new();
            cp.set("item_ids", id.to_string());
            if let Ok(content_result) = call_endpoint(server, "content", &cp).await {
                if let Some(content_data) = as_map(&extract_upstream_data(&content_result)).cloned()
                {
                    if let Some(c) = content_data.get("content").and_then(|v| v.as_str()) {
                        out.push_str(&format!("{}\n\n", strip_html_tags(c)));
                        wrote = true;
                    }
                }
            }
        }
        if !wrote {
            out.push('\n');
        }
    }

    Response::text(200, "text/plain; charset=utf-8", out.into_bytes())
}

/// `extractChapterList`.
pub fn extract_chapter_list(dir_result: &Value) -> Vec<Map<String, Value>> {
    let raw = extract_upstream_data(dir_result);
    if let Value::Array(direct) = &raw {
        return chapter_maps_from_raw(direct);
    }
    let Some(dir_data) = as_map(&raw) else {
        return Vec::new();
    };
    let Some(inner) = dir_data.get("data") else {
        return Vec::new();
    };
    if let Value::Array(direct) = inner {
        return chapter_maps_from_raw(direct);
    }
    let Some(d2) = as_map(inner) else {
        return Vec::new();
    };
    let Some(Value::Array(v_arr)) = d2.get("chapterListWithVolume") else {
        return Vec::new();
    };
    let mut chapters = Vec::new();
    for v in v_arr {
        if let Value::Array(direct) = v {
            chapters.extend(chapter_maps_from_raw(direct));
            continue;
        }
        let Some(vm) = as_map(v) else { continue };
        let Some(Value::Array(c_arr)) = vm.get("chapterList") else {
            continue;
        };
        chapters.extend(chapter_maps_from_raw(c_arr));
    }
    chapters
}

fn chapter_maps_from_raw(raw: &[Value]) -> Vec<Map<String, Value>> {
    let mut chapters = Vec::with_capacity(raw.len());
    for item in raw {
        let Some(cm) = as_map(item) else { continue };
        let mut ch = Map::new();
        let id = first_map_string(cm, &["itemId", "item_id", "chapter_id", "id"]);
        if !id.is_empty() {
            ch.insert("id".to_string(), Value::from(id));
        }
        let title = first_map_string(cm, &["title", "chapter_title", "name", "item_title"]);
        if !title.is_empty() {
            ch.insert("title".to_string(), Value::from(title));
        }
        chapters.push(ch);
    }
    chapters
}
