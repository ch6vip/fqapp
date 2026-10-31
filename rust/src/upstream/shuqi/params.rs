//! 公共参数表与设备身份。

use std::sync::OnceLock;

use rand::Rng;

/// 游客态默认 user id（搜索 / 详情 / 榜单）。
pub const APP_USER_ID: &str = "8158804976";
/// 章节接口专用 user id（目录探测与正文兜底）。
pub const CI_UID: &str = "8000000";

/// 公共参数表（35 键）。顺序无关 —— 输出顺序由 [`PUB_ORDER`] 决定。
pub(super) const PUB_PARAMS: &[(&str, &str)] = &[
    ("soft_id", "1"),
    ("user_id", APP_USER_ID),
    ("userId", APP_USER_ID),
    ("ver", "261013"),
    ("subVer", "sqrelease"),
    ("appVer", "12.7.0.268"),
    ("theme", "day"),
    ("platform", "an"),
    ("placeid", "1069"),
    ("sdk", "32"),
    ("cpu", "x86_64"),
    ("pkg_cpu", "arm64-v8a"),
    ("wh", "900x1600"),
    ("msv", "3"),
    ("vc", "5d73"),
    ("mod", "BVL-AN16"),
    ("manufacturer", "HONOR"),
    ("brand", "HONOR"),
    ("net_type", "wifi"),
    ("net_type_str", "wifi"),
    ("first_placeid", "src1069"),
    ("aak", "a3a840"),
    ("utype", "pre_vip"),
    ("net", "4"),
    ("net_env", "4"),
    ("permissionType", "0"),
    ("personalized", "1"),
    ("contentRecom", "1"),
    ("scene_code", ""),
    ("rom", "12"),
    ("sqUniqDeviceId", ""),
    ("utdid", ""),
    ("sn", ""),
    ("umidtoken", ""),
    ("otdd", ""),
];

/// `x-sq-public` 的键序：36 键，比 [`PUB_PARAMS`] 多一个 `enc`。
///
/// `timestamp` 虽然在构造时被赋值，但**不在**这个序列里，所以不会出现在串中。
pub(super) const PUB_ORDER: &[&str] = &[
    "soft_id",
    "user_id",
    "userId",
    "ver",
    "subVer",
    "appVer",
    "theme",
    "platform",
    "placeid",
    "sdk",
    "cpu",
    "pkg_cpu",
    "wh",
    "msv",
    "enc",
    "vc",
    "mod",
    "manufacturer",
    "brand",
    "net_type",
    "net_type_str",
    "first_placeid",
    "aak",
    "utype",
    "net",
    "net_env",
    "permissionType",
    "personalized",
    "contentRecom",
    "scene_code",
    "rom",
    "sqUniqDeviceId",
    "utdid",
    "sn",
    "umidtoken",
    "otdd",
];

/// 设备身份 5 字段。服务端不严格校验，但全员共用一份等于一个虚拟账号扛全部流量。
pub(super) const DEV_KEYS: &[&str] = &["sqUniqDeviceId", "utdid", "sn", "umidtoken", "otdd"];

/// 每次安装随机一次的设备身份。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Device {
    pub sq_uniq_device_id: String,
    pub utdid: String,
    pub sn: String,
    pub umidtoken: String,
    pub otdd: String,
}

impl Device {
    fn random() -> Self {
        Device {
            // 22 位字母数字
            sq_uniq_device_id: alnum(22),
            // 28 位字母数字
            utdid: alnum(28),
            // 16 位 hex
            sn: hex(8),
            // 40 位 hex
            umidtoken: hex(20),
            // 22 位字母数字
            otdd: alnum(22),
        }
    }

    pub(super) fn pairs(&self) -> Vec<(&'static str, String)> {
        vec![
            (DEV_KEYS[0], self.sq_uniq_device_id.clone()),
            (DEV_KEYS[1], self.utdid.clone()),
            (DEV_KEYS[2], self.sn.clone()),
            (DEV_KEYS[3], self.umidtoken.clone()),
            (DEV_KEYS[4], self.otdd.clone()),
        ]
    }
}

/// 进程级设备身份：只生成一次，不落盘、不发请求。
pub(super) fn device() -> &'static Device {
    static DEV: OnceLock<Device> = OnceLock::new();
    DEV.get_or_init(Device::random)
}

fn alnum(n: usize) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut rng = rand::thread_rng();
    (0..n)
        .map(|_| CHARS[rng.gen_range(0..CHARS.len())] as char)
        .collect()
}

fn hex(n_bytes: usize) -> String {
    let mut rng = rand::thread_rng();
    (0..n_bytes)
        .map(|_| format!("{:02x}", rng.gen_range(0..256u16)))
        .collect()
}
