//! Author endpoints. Port of author_info.go, author_bookshelf.go, rank_data.go
//! and tones.go.

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::base::{
    dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec, HOST_FQNOVEL,
};
use crate::endpoints::util::default_val;
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

const AUTHOR_INFO_PATH: &str = "/reading/user/basic_info/get/v";
const AUTHOR_BOOKSHELF_PATH: &str = "/reading/ugc/person/bookshelf/v";
const RANK_PATH: &str = "/reading/bookapi/bookmall/cell/change/v1/";
const TONES_PATH: &str = "/reading/bookapi/audio/toneinfo/";

/// The shared reading724Params() query bag from content_util.go.
fn reading724_params() -> Vec<(String, String)> {
    vec![
        ("iid".to_string(), "{install_id}".to_string()),
        ("device_id".to_string(), "{device_id}".to_string()),
        ("ac".to_string(), "wifi".to_string()),
        ("channel".to_string(), "xiaomi_1967_64".to_string()),
        ("aid".to_string(), "1967".to_string()),
        ("app_name".to_string(), "novelapp".to_string()),
        ("version_code".to_string(), "72432".to_string()),
        ("version_name".to_string(), "7.2.4.32".to_string()),
        ("device_platform".to_string(), "android".to_string()),
        ("os".to_string(), "android".to_string()),
        ("ssmix".to_string(), "a".to_string()),
        ("device_type".to_string(), "25053RT47C".to_string()),
        ("device_brand".to_string(), "Redmi".to_string()),
        ("language".to_string(), "zh".to_string()),
        ("os_api".to_string(), "36".to_string()),
        ("os_version".to_string(), "16".to_string()),
        ("manifest_version_code".to_string(), "72432".to_string()),
        ("resolution".to_string(), "1280*2620".to_string()),
        ("dpi".to_string(), "520".to_string()),
        ("update_version_code".to_string(), "72432".to_string()),
        ("host_abi".to_string(), "arm64-v8a".to_string()),
        ("dragon_device_type".to_string(), "phone".to_string()),
        ("pv_player".to_string(), "72432".to_string()),
        ("compliance_status".to_string(), "0".to_string()),
        ("need_personal_recommend".to_string(), "1".to_string()),
        ("player_so_load".to_string(), "1".to_string()),
        ("is_android_pad_screen".to_string(), "0".to_string()),
        (
            "rom_version".to_string(),
            "miui_V816_OS3.0.9.0.WOLCNXM".to_string(),
        ),
    ]
}

/// Go's url.Values.Set: replace every existing value for the key.
fn set_param(params: &mut Vec<(String, String)>, key: &str, value: &str) {
    params.retain(|(k, _)| k != key);
    params.push((key.to_string(), value.to_string()));
}

/// Go's reading724(overrides): the shared bag with the overrides applied.
fn reading724(overrides: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut params = reading724_params();
    for (key, value) in overrides {
        set_param(&mut params, key, value);
    }
    params
}

fn handle_author_info<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let author_id = params.get_str("author_id");
        if author_id.is_empty() {
            return Err(ApiError::BadRequest("缺少author_id参数".to_string()));
        }

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUTHOR_INFO_PATH.to_string(),
                params: reading724(&[("user_id", &author_id)]),
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_author_bookshelf<'a>(
    ctx: &'a Ctx,
    params: &'a Params,
) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let author_id = params.get_str("author_id");
        if author_id.is_empty() {
            return Err(ApiError::BadRequest("缺少author_id参数".to_string()));
        }
        let count = default_val(&params.get_str("count"), "30");
        let offset = default_val(&params.get_str("offset"), "0");

        let mut query = reading724_params();
        set_param(&mut query, "user_id", &author_id);
        set_param(&mut query, "count", &count);
        set_param(&mut query, "offset", &offset);
        set_param(&mut query, "tab_name", "");

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUTHOR_BOOKSHELF_PATH.to_string(),
                params: query,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_rank_data<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let rank_id = params.get_str("rank_id");
        if rank_id.is_empty() {
            return Err(ApiError::BadRequest("缺少rank_id参数".to_string()));
        }
        let offset = default_val(&params.get_str("offset"), "0");
        let genre_tab = default_val(&params.get_str("genre_tab"), "2");
        let rank_sub_info_id = default_val(&params.get_str("rank_sub_info_id"), "2");
        let algo_type = default_val(&params.get_str("algo_type"), "101");

        let mut query = reading724_params();
        set_param(&mut query, "cell_gender", "2");
        set_param(
            &mut query,
            "main_algo_type",
            "101,100,108,207,109,102,200,208,188,111,205",
        );
        set_param(&mut query, "genre_tab", &genre_tab);
        set_param(&mut query, "gender_list_type", "1");
        set_param(&mut query, "change_type", "1");
        set_param(&mut query, "rank_list_sub_tab_type_list", "1,2");
        set_param(&mut query, "algo_type", &algo_type);
        set_param(&mut query, "web_page_version_code", "1");
        set_param(&mut query, "tab_type", "2");
        set_param(&mut query, "list_gender", "1");
        set_param(&mut query, "limit", "12");
        set_param(
            &mut query,
            "genre_tab_name_list",
            "小说,出版,短剧,漫剧,听书,短篇",
        );
        set_param(&mut query, "support_gender_list", "true");
        set_param(&mut query, "cell_id", &rank_id);
        set_param(&mut query, "rank_sub_info_type", "0");
        set_param(&mut query, "book_type", "0");
        set_param(&mut query, "genre_tab_list", "2,3,4,5,6,7");
        set_param(&mut query, "rank_sub_info_id", &rank_sub_info_id);
        set_param(&mut query, "offset", &offset);
        set_param(&mut query, "web_page_key", "common-rank-list-v1");
        set_param(
            &mut query,
            "main_algo_name",
            "推荐榜,完本榜,新书榜,书友榜,追更榜,黑马榜,巅峰榜,书荒榜,礼物榜,阅读榜,作者榜",
        );
        set_param(&mut query, "list_type", "daily");
        set_param(&mut query, "rank_list_style_type", "1");
        set_param(&mut query, "client_req_type", "1");
        set_param(&mut query, "normal_session_cnt_in_day", "65");
        set_param(&mut query, "gender", "2");
        set_param(&mut query, "cold_start_session_cnt_in_day", "3");
        set_param(&mut query, "sys_mini_window", "1");
        set_param(&mut query, "app_mini_window", "0");
        set_param(&mut query, "har_status", "0");
        set_param(&mut query, "cold_start_session_cnt_in_life", "3");
        set_param(&mut query, "charging", "0");
        set_param(&mut query, "normal_session_cnt_in_life", "65");
        set_param(&mut query, "is_power_save_mode", "0");
        set_param(&mut query, "app_dark_mode", "0");
        set_param(&mut query, "screen_brightness", "40");
        set_param(&mut query, "battery_pct", "5");
        set_param(&mut query, "down_speed", "51412");
        set_param(&mut query, "sys_dark_mode", "0");
        set_param(&mut query, "font_scale", "100");
        set_param(&mut query, "network_type", "4");
        set_param(&mut query, "current_volume", "0");

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: RANK_PATH.to_string(),
                params: query,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

fn handle_tones<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: TONES_PATH.to_string(),
                params: reading724(&[
                    ("book_id", &book_id),
                    ("is_exempt", "false"),
                    ("is_local_book", "false"),
                ]),
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("author_info", handle_author_info);
    s.add_route("author_bookshelf", handle_author_bookshelf);
    s.add_route("rank_data", handle_rank_data);
    s.add_route("tones", handle_tones);
}
