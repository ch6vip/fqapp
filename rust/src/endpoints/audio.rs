//! Audio endpoints: book detail, chapter playinfo, audio play, and the
//! speech-text timeline.
//!
//! Port of /internal/endpoints/audio_book_detail.go,
//! audio_chapter_info.go, audio_play.go and audio_timeline.go.

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};

use crate::endpoints::base::{
    dragon_read_headers, dragon_read_json_headers, Upstream, UpstreamMode, UpstreamRequestSpec,
    HOST_FQNOVEL,
};
use crate::endpoints::util::{default_val, int_default, raw_json};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

/// Go's url.Values.Set.
fn set_param(params: &mut Vec<(String, String)>, key: &str, value: impl Into<String>) {
    let value = value.into();
    params.retain(|(k, _)| k != key);
    params.push((key.to_string(), value));
}

/// reading724Params from content_util.go.
fn reading_724_params() -> Vec<(String, String)> {
    [
        ("iid", "{install_id}"),
        ("device_id", "{device_id}"),
        ("ac", "wifi"),
        ("channel", "xiaomi_1967_64"),
        ("aid", "1967"),
        ("app_name", "novelapp"),
        ("version_code", "72432"),
        ("version_name", "7.2.4.32"),
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("device_type", "25053RT47C"),
        ("device_brand", "Redmi"),
        ("language", "zh"),
        ("os_api", "36"),
        ("os_version", "16"),
        ("manifest_version_code", "72432"),
        ("resolution", "1280*2620"),
        ("dpi", "520"),
        ("update_version_code", "72432"),
        ("host_abi", "arm64-v8a"),
        ("dragon_device_type", "phone"),
        ("pv_player", "72432"),
        ("compliance_status", "0"),
        ("need_personal_recommend", "1"),
        ("player_so_load", "1"),
        ("is_android_pad_screen", "0"),
        ("rom_version", "miui_V816_OS3.0.9.0.WOLCNXM"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

/// Audio book detail: GET /api/v1/audio/books/{id}.
const AUDIO_BOOK_DETAIL_PATH: &str = "/reading/bookapi/audio/detail/";

fn handle_book_detail<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }

        let mut p = reading_724_params();
        set_param(&mut p, "version", "v3");
        set_param(&mut p, "book_id", book_id);

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUDIO_BOOK_DETAIL_PATH.to_string(),
                params: p,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

/// Audio chapter playinfo: GET /api/v1/audio/books/{id}/chapters/{cid}.
const AUDIO_CHAPTER_INFO_PATH: &str = "/reading/reader/audio/playinfo/";

fn handle_chapter_info<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        let chapter_id = params.get_str("chapter_id");
        if book_id.is_empty() || chapter_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: book_id / chapter_id 均为必填".to_string(),
            ));
        }
        let tone_id = default_val(&params.get_str("tone_id"), "0");

        let mut p = reading_724_params();
        set_param(&mut p, "book_id", book_id);
        set_param(&mut p, "item_ids", chapter_id);
        set_param(&mut p, "tone_id", tone_id);
        set_param(&mut p, "req_type", "0");
        set_param(&mut p, "is_local_book", "false");

        let mut payload = Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUDIO_CHAPTER_INFO_PATH.to_string(),
                params: p,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await?;
        patch_playinfo_keys(&mut payload);
        Ok(payload)
    })
}

/// Derives key_hex for every encrypted stream inside an embedded
/// video_model JSON string; returns whether anything changed.
fn patch_model_stream_keys(model: &mut Map<String, Value>) -> bool {
    let Some(list) = model.get_mut("video_list").and_then(|v| v.as_array_mut()) else {
        return false;
    };
    let mut changed = false;
    for item in list.iter_mut() {
        let Some(stream) = item.as_object_mut() else {
            continue;
        };
        let Some(encryption) = stream
            .get_mut("encrypt_info")
            .and_then(|v| v.as_object_mut())
        else {
            continue;
        };
        if !encryption
            .get("encrypt")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            continue;
        }
        let spade_a = encryption
            .get("spade_a")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let key = crate::endpoints::video::derive_spade_content_key(&spade_a);
        if key.len() != 16 {
            continue;
        }
        encryption.insert("key_hex".to_string(), Value::String(hex::encode(&key)));
        changed = true;
    }
    changed
}

/// patchPlayinfoKeys: the playinfo answer nests the streams in
/// data[].video_model (a JSON string).
fn patch_playinfo_keys(v: &mut Value) {
    let Some(root) = v.as_object_mut() else {
        return;
    };
    let Some(rows) = root.get_mut("data").and_then(|d| d.as_array_mut()) else {
        return;
    };
    for row in rows.iter_mut() {
        let Some(entry) = row.as_object_mut() else {
            continue;
        };
        let raw_model = match entry.get("video_model").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => continue,
        };
        let Some(mut model) = crate::endpoints::video::decode_video_model_str(&raw_model) else {
            continue;
        };
        if !patch_model_stream_keys(&mut model) {
            continue;
        }
        if let Ok(patched) = serde_json::to_string(&model) {
            entry.insert("video_model".to_string(), Value::String(patched));
        }
    }
}

/// patchEncryptedAudioKeys: the audio player host nests the streams in
/// data.video_model_datas[].video_model (a JSON string).
fn patch_encrypted_audio_keys(v: &mut Value) {
    let Some(root) = v.as_object_mut() else {
        return;
    };
    let Some(data) = root.get_mut("data").and_then(|d| d.as_object_mut()) else {
        return;
    };
    let Some(rows) = data
        .get_mut("video_model_datas")
        .and_then(|r| r.as_array_mut())
    else {
        return;
    };
    for row in rows.iter_mut() {
        let Some(row_map) = row.as_object_mut() else {
            continue;
        };
        let raw_model = match row_map.get("video_model").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => continue,
        };
        let Some(mut model) = crate::endpoints::video::decode_video_model_str(&raw_model) else {
            continue;
        };
        if !patch_model_stream_keys(&mut model) {
            continue;
        }
        if let Ok(patched) = serde_json::to_string(&model) {
            row_map.insert("video_model".to_string(), Value::String(patched));
        }
    }
}

/// Audio playback: POST /api/v1/audio/play.
const AUDIO_PLAY_HOST: &str = "https://api5-sinfonlineb.novelfm.com";
const AUDIO_PLAY_PATH: &str = "/novelfm/playerapi/video_model/mget/v1";

/// Bounds how many pooled devices a single audio request may try.
const AUDIO_PLAY_ATTEMPTS: usize = 4;

fn handle_play<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_ids = params.get_str("item_ids");
        let book_id = params.get_str("book_id");
        if item_ids.is_empty() || book_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: item_ids / book_id 均为必填".to_string(),
            ));
        }

        let p: Vec<(String, String)> = [
            ("os", "android"),
            ("aid", "3040"),
            ("ssmix", "a"),
            ("manifest_version_code", "632"),
            ("dpi", "440"),
            ("device_brand", "Redmi"),
            ("language", "zh"),
            ("os_api", "35"),
            ("comment_tag_c", "5"),
            ("vip_state", "0"),
            ("host_abi", "arm64-v8a"),
            ("category_style", "1"),
            ("need_personal_recommend", "1"),
            ("rom_version", "miui_V816_OS3.0.1.0.VMRCNXM"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();

        let ids: Vec<String> = item_ids.split(',').map(|s| s.trim().to_string()).collect();
        let body = serde_json::to_vec(&json!({
            "audio_type": 0,
            "bgm_used": 0,
            "book_id": book_id,
            "device_score": 0,
            "item_ids": ids,
            "multi_shift": false,
            "source": "default",
            "tone_id": int_default(&params.get_str("tone_id"), 0),
            "user_select_start_para": 0,
            "user_select_start_para_off": 0,
        }))
        .map_err(|e| ApiError::Internal(format!("marshal audio play body: {e}")))?;

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::Signed,
            host: AUDIO_PLAY_HOST.to_string(),
            path: AUDIO_PLAY_PATH.to_string(),
            params: p,
            body: Some(body),
            headers: dragon_read_json_headers(),
            ..Default::default()
        };

        let mut v = Value::Null;
        for _ in 0..AUDIO_PLAY_ATTEMPTS {
            let raw = Upstream::new(ctx.up.clone()).raw(&spec).await?;
            v = raw_json(&raw)?;
            if !audio_play_device_rejected(&v) {
                break;
            }
        }
        patch_encrypted_audio_keys(&mut v);
        Ok(json!({
            "code": 0,
            "message": "success",
            "video_info": v,
        }))
    })
}

/// A body-level 401/403/429 means the pooled device was rejected.
fn audio_play_device_rejected(v: &Value) -> bool {
    let Some(payload) = v.as_object() else {
        return false;
    };
    let Some(code) = payload.get("code").and_then(|c| c.as_f64()) else {
        return false;
    };
    matches!(code as i64, 401 | 403 | 429)
}

/// Audio timeline: the speech-text request from audio_timeline.go.
pub const AUDIO_SPEECH_TEXT_HOST: &str = "https://api-sinfonlinea.fanqiesdk.com";
pub const AUDIO_SPEECH_TEXT_PATH: &str = "/api/novel/audio/speech/text/v1/";

fn handle_timeline<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
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

pub fn register(s: &mut Server) {
    s.add_route("audio_book_detail", handle_book_detail);
    s.add_route("audio_chapter_info", handle_chapter_info);
    s.add_route("audio_play", handle_play);
    s.add_route("audio_timeline", handle_timeline);
}

#[cfg(test)]
mod key_vectors {
    //! key_hex vectors copied from the reference implementation tests
    //! (internal/endpoints/audio_play_key_test.go, playinfo_key_test.go).

    use super::*;
    use serde_json::json;

    fn audio_model(spade_a: &str, kid: &str) -> String {
        format!(
            r#"{{"status":10,"media_type":"audio","video_duration":229.96,"video_list":[{{"main_url":"https://cdn/x","backup_url":"https://cdn/y","encrypt_info":{{"encrypt":true,"kid":"{kid}","spade_a":"{spade_a}","encryption_method":"cenc-aes-ctr"}}}}]}}"#
        )
    }

    #[test]
    fn patches_cenc_audio_keys_in_the_audio_play_shape() {
        let model = audio_model(
            "l7wZ+1azG8pUsS7NVIcYzWKCGvlWhCrVV5sa1lWsK+NnqC+2tg==",
            "692e7c06f8818b927094fff40092363a",
        );
        let mut value = json!({
            "data": { "video_model_datas": [ { "item_id": "7579131531361258521", "video_model": model } ] }
        });
        patch_encrypted_audio_keys(&mut value);

        let raw = value["data"]["video_model_datas"][0]["video_model"]
            .as_str()
            .unwrap();
        let parsed: Value = serde_json::from_str(raw).unwrap();
        let enc = &parsed["video_list"][0]["encrypt_info"];
        assert_eq!(enc["key_hex"], "61826b7eceb342a9ad4fd9d7556be625");
        assert_eq!(enc["encryption_method"], "cenc-aes-ctr");
    }

    #[test]
    fn leaves_plain_audio_streams_untouched() {
        let model =
            r#"{"status":10,"media_type":"audio","video_list":[{"main_url":"https://cdn/x"}]}"#;
        let mut value = json!({
            "data": { "video_model_datas": [ { "video_model": model } ] }
        });
        patch_encrypted_audio_keys(&mut value);
        assert_eq!(
            value["data"]["video_model_datas"][0]["video_model"],
            json!(model)
        );
    }

    #[test]
    fn patches_playinfo_keys_in_the_chapter_shape() {
        let model = audio_model(
            "nbwTwF23F/5phBHDb4Qjz3KBC/lBtzrJcLI4y2qGEc9dhRWhoQ==",
            "677752d8f8818bb4b2223c0e00f7a81a",
        );
        let mut value = json!({
            "code": 0,
            "data": [ { "item_id": "7181453438667096588", "video_model": model } ]
        });
        patch_playinfo_keys(&mut value);

        let raw = value["data"][0]["video_model"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(
            parsed["video_list"][0]["encrypt_info"]["key_hex"],
            "0f7a32fda0f04388ba27cf1d0a95b024"
        );
    }
}
