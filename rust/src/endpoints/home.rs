//! `homepage_recommend` and `series_feed` endpoints.
//! Port of `/internal/endpoints/homepage_recommend.go` and
//! `series_feed.go`. The private `reading724Params` builder below is copied
//! from `content_util.go` (it is not exposed by the Rust `content_util`
//! module).

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::base::HOST_FQNOVEL;
use crate::endpoints::base::{dragon_read_headers, Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::session::{record_device_session, session_id_from_response};
use crate::endpoints::util::{default_val, raw_json};
use crate::endpoints::{Ctx, Params, Server, INTERNAL_DEVICE_PIN_KEY};
use crate::error::{ApiError, ApiResult};

const HOMEPAGE_RECOMMEND_PATH: &str = "/reading/bookapi/bookmall/tab/v";
const SERIES_FEED_PATH: &str = "/reading/bookapi/bookmall/cell/change/v";

/// Go's `reading724Params` (content_util.go).
fn reading724_params() -> Params {
    let mut p = Params::new();
    p.set("iid", "{install_id}");
    p.set("device_id", "{device_id}");
    p.set("ac", "wifi");
    p.set("channel", "xiaomi_1967_64");
    p.set("aid", "1967");
    p.set("app_name", "novelapp");
    p.set("version_code", "72432");
    p.set("version_name", "7.2.4.32");
    p.set("device_platform", "android");
    p.set("os", "android");
    p.set("ssmix", "a");
    p.set("device_type", "25053RT47C");
    p.set("device_brand", "Redmi");
    p.set("language", "zh");
    p.set("os_api", "36");
    p.set("os_version", "16");
    p.set("manifest_version_code", "72432");
    p.set("resolution", "1280*2620");
    p.set("dpi", "520");
    p.set("update_version_code", "72432");
    p.set("host_abi", "arm64-v8a");
    p.set("dragon_device_type", "phone");
    p.set("pv_player", "72432");
    p.set("compliance_status", "0");
    p.set("need_personal_recommend", "1");
    p.set("player_so_load", "1");
    p.set("is_android_pad_screen", "0");
    p.set("rom_version", "miui_V816_OS3.0.9.0.WOLCNXM");
    p
}

fn homepage_recommend<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let client_template = default_val(&params.get_str("client_template"), "0");
        let tab_type = default_val(&params.get_str("tab_type"), "2");
        let offset = default_val(&params.get_str("offset"), "0");
        let session_id = params.get_str("session_id");

        let mut p = reading724_params();
        p.set("last_search_query_from_rec", "false");
        p.set("ClickedContent", "");
        p.set("client_template", client_template);
        p.set("last_tab_index", "0");
        p.set("screen_width_px", "1281");
        p.set("classic_tab_style", "v3");
        p.set("tab_type", tab_type);
        p.set("first_use_category_select", "false");
        p.set("last_session_video_tab_type", "0");
        p.set("current_name", "");
        p.set("disable_digg_stat", "false");
        p.set("ecom_refresh_type", "0");
        p.set("pad_column_cover", "0");
        p.set("last_tab_type", "0");
        p.set("req_rank_category_id", "0");
        p.set("video_tab_cold_start", "0");
        p.set("offset", offset);
        if !session_id.is_empty() {
            p.set("session_id", session_id.clone());
        }
        p.set("video_type_preferences_str", "[]");
        p.set("auth_aweme", "false");
        p.set("cold_start_is_double_gd", "false");
        p.set("page_entry_time", "0");
        p.set("cold_start_session", "1");
        p.set("tab_index", "0");
        p.set("lore_tab_style", "v5");
        p.set("device_level", "3");
        p.set("unlimited_short_series_change_type", "0");
        p.set("book_id", "0");
        p.set("ecom_impression_start_time", "0");
        p.set("enable_search_box_collapse", "false");
        p.set("landing_bottom_tab_type", "0");
        p.set("bottom_tab_type", "0");
        p.set("top_tab_extra", "");
        p.set("migration_top_tab_enable", "false");
        p.set("auth_backward", "true");
        p.set("pad_column_detail", "0");
        p.set("after_genre_preference_popup", "0");
        p.set("client_req_type", "1");
        p.set("req_rank_algo", "101");
        p.set("unlimited_short_series_next_offset", "0");
        p.set("normal_session_cnt_in_day", "6");
        p.set("cold_start_session_cnt_in_day", "2");
        p.set("sys_mini_window", "1");
        p.set("app_mini_window", "0");
        p.set("har_status", "0");
        p.set("cold_start_session_cnt_in_life", "2");
        p.set("charging", "0");
        p.set("normal_session_cnt_in_life", "6");
        p.set("is_power_save_mode", "0");
        p.set("app_dark_mode", "0");
        p.set("screen_brightness", "36");
        p.set("battery_pct", "10");
        p.set("down_speed", "51430");
        p.set("sys_dark_mode", "0");
        p.set("font_scale", "100");
        p.set("network_type", "4");
        p.set("current_volume", "0");

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: HOMEPAGE_RECOMMEND_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };

        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
            if !session_id.is_empty() {
                record_device_session(&session_id, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

fn series_feed<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let cell_id = params.get_str("cell_id");
        if cell_id.is_empty() {
            return Err(ApiError::BadRequest("缺少cell_id参数".to_string()));
        }

        let tab_type = default_val(&params.get_str("tab_type"), "16");
        let client_template = default_val(&params.get_str("client_template"), "2");
        let client_req_type = default_val(&params.get_str("client_req_type"), "2");
        let selector_change_type =
            default_val(&params.get_str("unlimited_selector_change_type"), "2");
        let screen_width_px = default_val(&params.get_str("screen_width_px"), "1281");
        let offset = default_val(&params.get_str("offset"), "0");
        let session_id = params.get_str("session_id");

        let mut p = reading724_params();
        p.set("cell_id", cell_id);
        p.set("last_search_query_from_rec", "false");
        p.set("ClickedContent", "");
        p.set("client_template", client_template);
        p.set("last_tab_index", "0");
        p.set("screen_width_px", screen_width_px);
        p.set("classic_tab_style", "v3");
        p.set("tab_type", tab_type);
        p.set("first_use_category_select", "false");
        p.set("last_session_video_tab_type", "0");
        p.set("current_name", "");
        p.set("disable_digg_stat", "false");
        p.set("ecom_refresh_type", "0");
        p.set("pad_column_cover", "0");
        p.set("last_tab_type", "0");
        p.set("req_rank_category_id", "0");
        p.set("video_tab_cold_start", "0");
        p.set("offset", offset);
        let cell_name = params.get_str("cell_name");
        if !cell_name.is_empty() {
            p.set("cell_name", cell_name);
        }
        let cell_sub_id = params.get_str("cell_sub_id");
        if !cell_sub_id.is_empty() {
            p.set("cell_sub_id", cell_sub_id);
        }
        let selected_items = params.get_str("selected_items");
        if !selected_items.is_empty() {
            p.set("selected_items", selected_items);
        }
        let sub_selected_items = params.get_str("sub_selected_items");
        if !sub_selected_items.is_empty() {
            p.set("sub_selected_items", sub_selected_items);
        }
        if !session_id.is_empty() {
            p.set("session_id", session_id.clone());
        }
        let filter_ids = params.get_str("filter_ids");
        if !filter_ids.is_empty() {
            p.set("filter_ids", filter_ids);
        }
        p.set("video_type_preferences_str", "[]");
        p.set("auth_aweme", "false");
        p.set("cold_start_is_double_gd", "false");
        p.set("page_entry_time", "0");
        p.set("cold_start_session", "1");
        p.set("tab_index", "0");
        p.set("lore_tab_style", "v5");
        p.set("device_level", "3");
        p.set("unlimited_short_series_change_type", "0");
        p.set("unlimited_selector_change_type", selector_change_type);
        p.set("book_id", "0");
        p.set("ecom_impression_start_time", "0");
        p.set("enable_search_box_collapse", "false");
        p.set("landing_bottom_tab_type", "0");
        p.set("bottom_tab_type", "0");
        p.set("top_tab_extra", "");
        p.set("migration_top_tab_enable", "false");
        p.set("auth_backward", "true");
        p.set("pad_column_detail", "0");
        p.set("after_genre_preference_popup", "0");
        p.set("client_req_type", client_req_type);
        p.set("req_rank_algo", "101");
        p.set("unlimited_short_series_next_offset", "0");
        p.set("normal_session_cnt_in_day", "6");
        p.set("cold_start_session_cnt_in_day", "2");
        p.set("sys_mini_window", "1");
        p.set("app_mini_window", "0");
        p.set("har_status", "0");
        p.set("cold_start_session_cnt_in_life", "2");
        p.set("charging", "0");
        p.set("normal_session_cnt_in_life", "6");
        p.set("is_power_save_mode", "0");
        p.set("app_dark_mode", "0");
        p.set("screen_brightness", "36");
        p.set("battery_pct", "10");
        p.set("down_speed", "51430");
        p.set("sys_dark_mode", "0");
        p.set("font_scale", "100");
        p.set("network_type", "4");
        p.set("current_volume", "0");

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: SERIES_FEED_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };

        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
            if !session_id.is_empty() {
                record_device_session(&session_id, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

/// 频道表（官方 `GET /reading/bookapi/bookmall/tab/v`，`BookstoreTabResponse`
/// 的 `data: TabDataList`，其 `tab_item` 是 `Vec<BookstoreTabData>`）。
///
/// 官方**不用静态频道表**：`m0.java:3051-3089` 把 `tab_item` 逐条转成
/// `BookMallTabData`，名字直接取 `bookstoreTabData.title`（`:3058`），
/// 类型取 `tab_type`（`:3086`）。本路由把这两段原样透传，客户端的频道条
/// 就由服务端配置驱动。
///
/// 参数是 `tab_type`（当前选中的频道）与 `last_tab_type`（上次选中的频道，
/// 官方存 SP `last_tab_type`，无值 -1）：与 `homepage_recommend` 不同的地方
/// 是这里**必须**原样返回整个 `tab_item`，不能只挑一个 tab。
///
/// `bottom_tab_type` 必须是 7（官方 `BottomTabBarItemType.VideoSeriesFeedTab`
/// = 7，书城才是 0）：服务端靠它区分语境，0 会拿到**书城**频道条
///（书城把 video_feed=16 那条叫「视频」，且没有最近/收藏），短剧页的频道条
/// 就会塌成「看剧/视频」两条。`client_req_type` 同理对齐官方进页语义
/// `ClientReqType.Open` = 3（我们此前发 1 = Refresh）。
/// 证据：J:seriesmall/SeriesMallVM.java:141-176、J:rpc/model/BottomTabBarItemType.java、
/// J:rpc/model/ClientReqType.java。
fn channel_tabs<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let tab_type = default_val(&params.get_str("tab_type"), "16");
        let last_tab_type = default_val(&params.get_str("last_tab_type"), "-1");
        let mut p = reading724_params();
        p.set("tab_type", tab_type);
        p.set("last_tab_type", last_tab_type);
        p.set("client_template", "0");
        p.set("bottom_tab_type", "7");
        p.set("landing_bottom_tab_type", "0");
        p.set("client_req_type", "3");
        p.set("app_mode", "0");
        p.set("classic_tab_style", "v3");
        p.set("lore_tab_style", "v5");
        p.set("migration_top_tab_enable", "false");
        p.set("auth_aweme", "false");
        p.set("auth_backward", "true");
        p.set("cold_start_is_double_gd", "false");
        p.set("after_genre_preference_popup", "0");
        p.set("first_use_category_select", "false");
        p.set("current_name", "");
        p.set("book_id", "0");
        p.set("last_tab_index", "0");
        p.set("enable_search_box_collapse", "false");
        p.set("top_tab_extra", "");

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            host: HOST_FQNOVEL.to_string(),
            path: HOMEPAGE_RECOMMEND_PATH.to_string(),
            params: p.to_pairs(),
            headers: dragon_read_headers(),
            pin_device: params.get_str(INTERNAL_DEVICE_PIN_KEY),
            ..Default::default()
        };
        let (raw, dev) = Upstream::new(ctx.up.clone()).raw_with_device(&spec).await?;
        if !dev.device_id.is_empty() {
            let opened = session_id_from_response(&raw);
            if !opened.is_empty() {
                record_device_session(&opened, &dev.device_id);
            }
        }
        raw_json(&raw)
    })
}

pub fn register(s: &mut Server) {
    s.add_route("homepage_recommend", homepage_recommend);
    s.add_route("channel_tabs", channel_tabs);
    s.add_route("series_feed", series_feed);
}
