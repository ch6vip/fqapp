//! 书旗（`ocean.shuqireader.com`）上游协议层。
//!
//! 移植自 `书旗-轻页原生.json` 内嵌的 `js` 脚本库（`sqKs` / `sqEnc` / `sqSign` /
//! `sqEnc18` / `sqPublicStr` / `sqAppBody` / `sqRot` / `sqDecodeContent`）。
//!
//! 三条约束必须原样保持，写错任何一条服务端都会直接拒：
//!
//! 1. keystream 只能做**二进制** base64 解码。按 UTF-8 文本解码会把 2048 字节
//!    膨胀到 5000 以上（源脚本注释记的 118585 字节就是这个坑），签名与加密全错；
//! 2. `data` 与 `x-sq-public` 是**两条独立消息**，各自从 `keystream[0]` 起算，
//!    不是一条长消息的两段；
//! 3. 请求体里 `platform="an"`，`x-sq-public` 串里 `platform="2"` —— 不是笔误。
//!
//! 这套上游不需要番茄那套设备签名，走 `UpstreamMode::NoSign` 即可，但必须自带
//! `okhttp/3.12.13` 的 UA（上游层会先注入 dragon 的默认 UA，自定义头能覆盖）。
//!
//! 模块按职责拆分：[`params`] 公共参数与设备身份、[`crypto`] 签名与加密、
//! [`request`] 请求体、[`url`] 接口地址、[`content`] 正文解码。

mod content;
mod crypto;
mod params;
mod request;
mod url;

pub use content::{decode_content, parse_cdn_payload, rot13, strip_tags};
pub use crypto::{enc18, keystream, md5_hex, now_ms, public_str, sign};
pub use params::{Device, APP_USER_ID, CI_UID};
pub use request::{app_body, app_body_with_device, AppRequest};
pub use url::{content_cdn_url, path, toc_h5_url, HOST, UA};

#[cfg(test)]
mod tests;
