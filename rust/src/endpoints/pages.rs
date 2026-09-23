//! Raw HTML page endpoints (`player`, `manga_reader`).
//! Port of `player.go` and `manga_reader.go`.

use futures::future::BoxFuture;

use crate::endpoints::{Ctx, Params, RawOut, Server};
use crate::error::ApiResult;

const PLAYER_HTML: &str = include_str!("../../assets/player.html");
const MANGA_READER_HTML: &str = include_str!("../../assets/manga_reader.html");

/// `jsStr`: JSON-encodes a string for safe embedding in the page's JS.
fn js_str(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn render_viewer_html(template: &str, q: &Params) -> RawOut {
    let mut item_id = q.get_str("item_id");
    if item_id.is_empty() {
        item_id = q.get_str("item_ids");
    }
    let mut book_id = q.get_str("book_id");
    if book_id.is_empty() {
        book_id = q.get_str("fq_id");
    }
    if item_id.is_empty() && book_id.is_empty() {
        return RawOut {
            status: 200,
            content_type: "text/plain; charset=utf-8".to_string(),
            body: "缺少参数: item_id 或 book_id".as_bytes().to_vec(),
        };
    }
    let page = template
        .replace("__BOOK_ID__", &js_str(&book_id))
        .replace("__ITEM_ID__", &js_str(&item_id));
    RawOut {
        status: 200,
        content_type: "text/html; charset=utf-8".to_string(),
        body: page.into_bytes(),
    }
}

fn player<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<RawOut>> {
    Box::pin(async move { Ok(render_viewer_html(PLAYER_HTML, params)) })
}

fn manga_reader<'a>(_ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<RawOut>> {
    Box::pin(async move { Ok(render_viewer_html(MANGA_READER_HTML, params)) })
}

pub fn register(s: &mut Server) {
    s.add_raw("player", player);
    s.add_raw("manga_reader", manga_reader);
}
