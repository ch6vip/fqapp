//! `wkcontent` endpoint: audio speech text. Port of `wkcontent.go`.

use futures::future::BoxFuture;
use serde_json::Value;

use crate::endpoints::base::{Upstream, UpstreamMode, UpstreamRequestSpec};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

pub const AUDIO_SPEECH_TEXT_HOST: &str = "https://api-sinfonlinea.fanqiesdk.com";
pub const AUDIO_SPEECH_TEXT_PATH: &str = "/api/novel/audio/speech/text/v1/";

const WKCONTENT_FIXED_QUERY_SUFFIX: &str = "&device_platform=android&os=android&ssmix=a&aid=6589&app_name=gold_browser&version_code=150800&version_name=15.8.0&manifest_version_code=15800&update_version_code=15800&ab_group=94569,102754&ab_feature=94563,102749&resolution=1080*1920&dpi=480&device_type=FRD-AL10&device_brand=honor&language=zh&os_api=28&os_version=9&ac=wifi&current_launch_mode=enter_launch&pass_through=update64&recommend_switch=true&current_launch_mode_hot=enter_launch&is_db=0&today_first_launch_mode=enter_launch&dq_param=1&isTTWebViewHeifSupport=0&plugin=0&openlive_plugin_status=0&client_vid=13599182,15697199,13812938&rom_version=28&iid={install_id}&device_id={device_id}";

fn wkcontent_headers() -> Vec<(String, String)> {
    vec![
        ("User-Agent".to_string(), "com.cat.readall/15800 (Linux; U; Android 9; zh_CN; FRD-AL10; Build/HUAWEIFRD-AL10; Cronet/TTNetVersion:fc4cebd3 2024-12-10 QuicVersion:d9628e3d 2024-10-11)".to_string()),
        ("sdk-version".to_string(), "2".to_string()),
        ("passport-sdk-version".to_string(), "505317".to_string()),
        ("x-vc-bdturing-sdk-version".to_string(), "4.0.3.cn".to_string()),
        ("x-tt-request-tag".to_string(), "n=0;s=1;p=0".to_string()),
        ("x-ss-dp".to_string(), "6589".to_string()),
    ]
}

pub async fn fetch_wkcontent(
    ctx: &Ctx,
    item_ids: &str,
    genre: &str,
    tone_id: &str,
) -> ApiResult<Value> {
    let u = format!(
        "{AUDIO_SPEECH_TEXT_HOST}{AUDIO_SPEECH_TEXT_PATH}?item_id={}&genre={}&tone_id={}{WKCONTENT_FIXED_QUERY_SUFFIX}",
        crate::endpoints::util::go_query_escape(item_ids),
        crate::endpoints::util::go_query_escape(genre),
        crate::endpoints::util::go_query_escape(tone_id),
    );
    Upstream::new(ctx.up.clone())
        .json(&UpstreamRequestSpec {
            mode: UpstreamMode::DeviceSigned,
            raw_url: Some(u),
            headers: wkcontent_headers(),
            ..Default::default()
        })
        .await
}

fn handle<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_ids = params.get_str("item_ids");
        if item_ids.is_empty() {
            return Err(ApiError::BadRequest("缺少item_ids参数".to_string()));
        }
        let genre = crate::endpoints::util::default_val(&params.get_str("genre"), "4");
        let tone_id = crate::endpoints::util::default_val(&params.get_str("tone_id"), "99");
        fetch_wkcontent(ctx, &item_ids, &genre, &tone_id).await
    })
}

pub fn register(s: &mut Server) {
    s.add_route("wkcontent", handle);
}
