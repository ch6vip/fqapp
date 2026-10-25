//! 听书文本同步端点：字幕时间轴与朗读位置映射。
//!
//! 两个端点服务于「边听边读」：
//! * `timeline`  —— 播报文本 + 起始毫秒，给字幕面板用；
//! * `timepoint` —— 音频毫秒 → 正文段落/字符偏移，给正文朗读高亮用。
//!
//! 它们的共同点是都以音频时间为基准去对齐文本，且都需要真实的 `tone_id`
//! 才返回内容，所以放在一起。

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::audio::{reading_724_params, set_param};
use crate::endpoints::base::{
    dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec, HOST_FQNOVEL,
};
use crate::endpoints::util::default_val;
use crate::endpoints::{Ctx, Params};
use crate::error::{ApiError, ApiResult};

/// Audio timeline: the speech-text request from audio_timeline.go.
pub const AUDIO_SPEECH_TEXT_HOST: &str = "https://api-sinfonlinea.fanqiesdk.com";
pub const AUDIO_SPEECH_TEXT_PATH: &str = "/api/novel/audio/speech/text/v1/";

pub(crate) fn handle_timeline<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_id = default_val(&params.get_str("item_id"), &params.get_str("item_ids"));
        if item_id.is_empty() {
            return Err(ApiError::BadRequest("缺少item_id参数".to_string()));
        }
        let genre = default_val(&params.get_str("genre"), "4");
        let tone_id = default_val(&params.get_str("tone_id"), "99");

        let mut p: Vec<(String, String)> = Vec::new();
        set_param(&mut p, "item_id", item_id);
        set_param(&mut p, "genre", genre);
        set_param(&mut p, "tone_id", tone_id);
        for (k, v) in [
            ("device_platform", "android"),
            ("os", "android"),
            ("ssmix", "a"),
            ("aid", "6589"),
            ("app_name", "gold_browser"),
            ("version_code", "150800"),
            ("version_name", "15.8.0"),
            ("manifest_version_code", "15800"),
            ("update_version_code", "158004"),
            ("ab_group", "94569,102754"),
            ("ab_feature", "94563,102749"),
            ("resolution", "1080*1920"),
            ("dpi", "480"),
            ("device_type", "FRD-AL10"),
            ("device_brand", "honor"),
            ("language", "zh"),
            ("os_api", "28"),
            ("os_version", "9"),
            ("ac", "wifi"),
            ("current_launch_mode", "enter_launch"),
            ("pass_through", "update64"),
            ("recommend_switch", "true"),
            ("current_launch_mode_hot", "enter_launch"),
            ("is_db", "0"),
            ("today_first_launch_mode", "enter_launch"),
            ("dq_param", "1"),
            ("isTTWebViewHeifSupport", "0"),
            ("plugin", "0"),
            ("openlive_plugin_status", "0"),
            ("client_vid", "13599182,15697199,13812938"),
            ("rom_version", "28"),
            ("iid", "{install_id}"),
            ("device_id", "{device_id}"),
        ] {
            set_param(&mut p, k, v);
        }

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: AUDIO_SPEECH_TEXT_HOST.to_string(),
                path: AUDIO_SPEECH_TEXT_PATH.to_string(),
                params: p,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

/// Audio time points: GET → `/reading/reader/audio/timepoint/`.
///
/// Mirrors the official `AudioTimePointRequest` (`ro4/f.java` `$GET
/// /reading/reader/audio/timepoint/`). The answer is the mapping that makes
/// listen-along highlighting possible without any text matching: each entry
/// carries `start_para` / `start_para_off` / `end_para` / `end_para_off`
/// (paragraph index plus character offset inside it) against an audio window
/// `start_time` / `end_time` in milliseconds.
///
/// `req_type` selects which timeline is asked for (`AudioTimePointReqType`):
/// 1 = tts (智能朗读), 2 = audio (真人讲书), 3 = para_match_audio,
/// 4 = para_match_text, 5 = local book tts.
///
/// Measured against the live upstream (2026-10), **3 is the one that answers
/// with usable offsets**: 1 replies `101049 TTS_MAY_HASNT_PRODUCT` for books
/// without generated speech, 2 replies `101002 NOVEL_DATA_GET_ERROR`, and 4
/// answers `code:0` but with every offset zero and `positionV2: null`. Only 3
/// carries the paragraph ranges the reader needs, so it is the default here.
const AUDIO_TIMEPOINT_PATH: &str = "/reading/reader/audio/timepoint/";

pub(crate) fn handle_timepoint<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        let item_id = default_val(&params.get_str("item_id"), &params.get_str("chapter_id"));
        if book_id.is_empty() || item_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: book_id / item_id 均为必填".to_string(),
            ));
        }
        let tone_id = default_val(&params.get_str("tone_id"), "0");
        let req_type = default_val(&params.get_str("req_type"), "3");

        let mut p = reading_724_params();
        set_param(&mut p, "book_id", book_id);
        set_param(&mut p, "item_id", item_id);
        set_param(&mut p, "tone_id", tone_id);
        set_param(&mut p, "req_type", req_type);

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUDIO_TIMEPOINT_PATH.to_string(),
                params: p,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}
