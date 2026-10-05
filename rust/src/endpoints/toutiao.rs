//! `toutiao` endpoint: DH-encrypted toutiao chapter content.

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::dhcontent::fetch_novel_reader_content;
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_id = params.get_str("item_ids");
        if item_id.is_empty() {
            return Err(ApiError::BadRequest("请提供 item_ids 参数".to_string()));
        }
        fetch_novel_reader_content(ctx, &item_id).await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("toutiao", handle);
}
