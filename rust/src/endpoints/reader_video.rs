//! Read-only novel-to-adaptation mapping used by the reader's video entry.

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::audio::{reading_724_params, set_param};
use crate::endpoints::base::{
    dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec, HOST_FQNOVEL,
};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

fn video_match<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("book_id is required".to_string()));
        }
        let mut query = reading_724_params();
        set_param(&mut query, "book_id", book_id);
        // V2's prepareNovelToVideoData uses MatchMotionComic (2).
        set_param(&mut query, "req_type", "2");
        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: "/reading/reader/video/timepoint/".to_string(),
                params: query,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

pub fn register(server: &mut Server) {
    server.add_route("reader_video_match", video_match);
}
