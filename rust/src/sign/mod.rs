//! Upstream request signing.
//!
//! Every primitive is byte-exact against the golden vectors in
//! `rust/testdata/vectors.json`, which were produced by an independent
//! reference implementation rather than this crate.

pub mod abogus;
pub mod argus;
pub mod gorgon;
pub mod ladon;
pub mod protobuf;
pub mod simon;
pub mod sm3;

use md5::{Digest, Md5};
use rand::Rng;

pub use argus::{ArgusBeanStyle, ArgusParams};

/// Effective headers for the novel app (aid=1967): x-ss-req-ticket, x-khronos,
/// x-argus, x-ladon and (POST only) x-ss-stub. x-gorgon is legacy/dead for the
/// current upstream and is off by default.
#[derive(Debug, Clone)]
pub struct Manager {
    pub aid: i64,
    pub license_id: i64,
    pub enable_gorgon: bool,
    pub argus_style: ArgusBeanStyle,
    pub fixed_argus_rand: i32,
}

impl Default for Manager {
    fn default() -> Self {
        Self::new()
    }
}

impl Manager {
    pub fn new() -> Self {
        Manager {
            aid: 1967,
            license_id: 1_611_921_764,
            enable_gorgon: false,
            argus_style: ArgusBeanStyle::ArgusBean551,
            fixed_argus_rand: 0,
        }
    }

    fn aid_from_query(&self, query_string: &str) -> i64 {
        if !query_string.is_empty() {
            if let Some(v) = query_param(query_string, "aid") {
                if let Ok(n) = v.parse::<i64>() {
                    return n;
                }
            }
        }
        self.aid
    }

    pub fn generate_headers(
        &self,
        query_string: &str,
        post_data: Option<&[u8]>,
    ) -> Vec<(String, String)> {
        self.generate_headers_with_opts(query_string, post_data, &HeaderOpts::default())
    }

    pub fn generate_headers_with_opts(
        &self,
        query_string: &str,
        post_data: Option<&[u8]>,
        opt: &HeaderOpts,
    ) -> Vec<(String, String)> {
        self.generate_headers_at(
            query_string,
            post_data,
            opt,
            timeutil_now_secs(),
            rand::thread_rng().gen::<[u8; 4]>(),
            None,
        )
    }

    /// Deterministic variant used by tests: caller supplies the timestamp, the
    /// 4 Ladon key bytes and (optionally) the Argus bean field 3 nonce.
    pub fn generate_headers_at(
        &self,
        query_string: &str,
        post_data: Option<&[u8]>,
        opt: &HeaderOpts,
        ts: i64,
        ladon_random: [u8; 4],
        argus_rand: Option<i32>,
    ) -> Vec<(String, String)> {
        let aid = self.aid_from_query(query_string);

        let mut stub_hex = String::new();
        let stub_src: Option<&[u8]> = match &opt.stub_body {
            Some(b) => Some(b.as_slice()),
            None => post_data,
        };
        if !opt.skip_stub {
            if let Some(src) = stub_src {
                if !src.is_empty() {
                    let mut hasher = Md5::new();
                    hasher.update(src);
                    stub_hex = hex::encode(hasher.finalize());
                }
            }
        }

        let mut headers: Vec<(String, String)> = Vec::new();
        headers.push(("x-ss-req-ticket".into(), (ts * 1000).to_string()));
        headers.push(("x-khronos".into(), ts.to_string()));
        if !opt.skip_ladon {
            headers.push((
                "x-ladon".into(),
                ladon::ladon_encrypt(ts, self.license_id, aid, &ladon_random),
            ));
        }
        if !opt.skip_argus {
            let rand_field = argus_rand.unwrap_or_else(|| rand::thread_rng().gen::<i32>());
            headers.push((
                "x-argus".into(),
                argus::argus_get_sign(&ArgusParams {
                    query_string: query_string.to_string(),
                    stub_hex: stub_hex.clone(),
                    timestamp: ts,
                    aid,
                    license_id: self.license_id,
                    device_id: query_param(query_string, "device_id").unwrap_or_default(),
                    install_id: opt.install_id_field16.clone(),
                    style: self.argus_style,
                    rand_field,
                }),
            ));
        }
        if !stub_hex.is_empty() {
            headers.push(("x-ss-stub".into(), stub_hex));
        }
        if self.enable_gorgon {
            headers.push(("x-gorgon".into(), gorgon::generate_x_gorgon(query_string)));
        }
        headers
    }
}

fn timeutil_now_secs() -> i64 {
    crate::timeutil::now_secs()
}

/// HeaderOpts tweaks signature assembly for probes.
#[derive(Debug, Clone, Default)]
pub struct HeaderOpts {
    /// Overrides what gets MD5'd into x-ss-stub (None = use the caller's body).
    pub stub_body: Option<Vec<u8>>,
    pub skip_ladon: bool,
    pub skip_argus: bool,
    pub skip_stub: bool,
    /// Sets Argus bean field 16 when non-empty.
    pub install_id_field16: String,
}

/// Go's `url.Values.Get` on a raw query string.
pub fn query_param(query_string: &str, name: &str) -> Option<String> {
    for (k, v) in url::form_urlencoded::parse(query_string.as_bytes()) {
        if k == name {
            return Some(v.into_owned());
        }
    }
    None
}
