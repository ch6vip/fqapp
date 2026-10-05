//! Endpoint registry and request context.
//!
//! One `Server` owns the route table; the FFI bridge, the loopback HTTP
//! adapter and the built-in Web UI all dispatch through it. Endpoint names and
//! path matching are identical across all three dispatch paths.

pub mod audio;
pub mod author;
pub mod base;
pub mod book;
pub mod comments;
pub mod content;
pub mod content_util;
pub mod dhcontent;
pub mod full;
pub mod home;
pub mod manga;
pub mod pages;
pub mod router;
pub mod search;
pub mod session;
pub mod toutiao;
pub mod util;
pub mod video;
pub mod webui;
pub mod wkcontent;

use std::collections::HashMap;
use std::sync::Arc;

use futures::future::BoxFuture;
use serde_json::Value;

use crate::config::Config;
use crate::device::DevicePool;
use crate::error::ApiResult;
use crate::filter::FilterManager;
use crate::upstream::UpstreamClient;

pub const INTERNAL_DEVICE_PIN_KEY: &str = "_pinned_device";

/// Query/param bag mirroring Go's `url.Values` for the operations the
/// endpoints use (Get returns the first value, Set replaces all).
#[derive(Debug, Clone, Default)]
pub struct Params {
    items: Vec<(String, String)>,
}

impl Params {
    pub fn new() -> Self {
        Params::default()
    }

    pub fn from_pairs(items: Vec<(String, String)>) -> Self {
        Params { items }
    }

    /// Parses a raw query string the way Go's `r.URL.Query()` does.
    pub fn parse(query: &str) -> Self {
        let mut items = Vec::new();
        for (k, v) in url::form_urlencoded::parse(query.as_bytes()) {
            items.push((k.into_owned(), v.into_owned()));
        }
        Params { items }
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.items
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    pub fn get_str(&self, key: &str) -> String {
        self.get(key).unwrap_or("").to_string()
    }

    pub fn contains(&self, key: &str) -> bool {
        self.items.iter().any(|(k, _)| k == key)
    }

    /// Go's `url.Values.Set`: replaces every existing value.
    pub fn set(&mut self, key: &str, value: impl Into<String>) {
        let value = value.into();
        self.items.retain(|(k, _)| k != key);
        self.items.push((key.to_string(), value));
    }

    pub fn remove(&mut self, key: &str) {
        self.items.retain(|(k, _)| k != key);
    }

    pub fn get_int(&self, key: &str, default: i64) -> i64 {
        match self.get(key) {
            Some(v) if !v.is_empty() => v.parse::<i64>().unwrap_or(default),
            _ => default,
        }
    }

    pub fn iter(&self) -> impl Iterator<Item = &(String, String)> {
        self.items.iter()
    }

    pub fn to_pairs(&self) -> Vec<(String, String)> {
        self.items.clone()
    }

    /// Go's `url.Values.Encode()` with the device placeholders restored.
    pub fn encoded(&self) -> String {
        util::encode_query(&self.items)
    }
}

/// Shared state every endpoint needs.
pub struct Ctx {
    pub up: Arc<UpstreamClient>,
    pub pool: Arc<DevicePool>,
    pub cfg: Arc<Config>,
    pub src_dir: String,
    pub web_dir: String,
    pub filters: Arc<FilterManager>,
}

pub type Handler = for<'a> fn(&'a Ctx, &'a Params) -> BoxFuture<'a, ApiResult<Value>>;

/// Output of an HTML page endpoint, which bypasses the JSON envelope.
pub struct RawOut {
    pub status: u16,
    pub content_type: String,
    pub body: Vec<u8>,
}

pub type RawHandler = for<'a> fn(&'a Ctx, &'a Params) -> BoxFuture<'a, ApiResult<RawOut>>;

pub struct Server {
    pub ctx: Arc<Ctx>,
    routes: HashMap<&'static str, Handler>,
    raw: HashMap<&'static str, RawHandler>,
}

impl Server {
    pub fn new(ctx: Arc<Ctx>) -> Self {
        let mut s = Server {
            ctx,
            routes: HashMap::new(),
            raw: HashMap::new(),
        };
        server::register_all(&mut s);
        s
    }

    pub fn add_route(&mut self, name: &'static str, handler: Handler) {
        self.routes.insert(name, handler);
    }

    pub fn add_raw(&mut self, name: &'static str, handler: RawHandler) {
        self.raw.insert(name, handler);
    }

    pub fn handler(&self, name: &str) -> Option<Handler> {
        self.routes.get(name).copied()
    }

    pub fn raw_handler(&self, name: &str) -> Option<RawHandler> {
        self.raw.get(name).copied()
    }
}

/// The single place that wires every endpoint module into the route table.
pub mod server {
    use super::*;

    pub fn register_all(s: &mut Server) {
        search::register(s);
        home::register(s);
        book::register(s);
        content::register(s);
        full::register(s);
        toutiao::register(s);
        wkcontent::register(s);
        comments::register(s);
        author::register(s);
        audio::register(s);
        video::register(s);
        manga::register(s);
        pages::register(s);
    }
}
