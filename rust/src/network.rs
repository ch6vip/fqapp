//! Windows outbound policy; other platforms retain reqwest's default routing.
//! Windows client caches rotate with each core initialization.
use std::sync::{Mutex, RwLock};

use crate::config::NetworkProxy;

#[derive(Clone, Default)]
pub(crate) struct Policy {
    generation: u64,
    #[cfg(target_os = "windows")]
    proxy: Option<reqwest::Proxy>,
}
static POLICY: RwLock<Policy> = RwLock::new(Policy {
    generation: 0,
    #[cfg(target_os = "windows")]
    proxy: None,
});

#[cfg(any(target_os = "windows", test))]
impl NetworkProxy {
    pub(crate) fn validate(&self) -> Result<Option<reqwest::Proxy>, String> {
        if !self.enabled {
            return Ok(None);
        }
        let invalid = || {
            "network_proxy.url must be http/https/socks5/socks5h://host:port without credentials, path, query or fragment".to_string()
        };
        let url = url::Url::parse(&self.url).map_err(|_| invalid())?;
        let authority = self
            .url
            .split_once("://")
            .ok_or_else(invalid)?
            .1
            .split(['/', '?', '#'])
            .next()
            .ok_or_else(invalid)?;
        let port = authority
            .rsplit_once(':')
            .and_then(|(_, port)| port.parse::<u16>().ok());
        if self.url.chars().any(char::is_whitespace)
            || !matches!(url.scheme(), "http" | "https" | "socks5" | "socks5h")
            || url.host_str().is_none()
            || !port.is_some_and(|port| port != 0)
            || authority.contains('@')
            || authority.contains('%')
            || !matches!(url.path(), "" | "/")
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err(invalid());
        }
        reqwest::Proxy::all(url.as_str())
            .map(Some)
            .map_err(|_| invalid())
    }
}

#[cfg(not(target_os = "windows"))]
pub(crate) fn apply(_config: &NetworkProxy) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "windows")]
pub(crate) fn apply(config: &NetworkProxy) -> Result<(), String> {
    let proxy = config.validate()?;
    let mut policy = POLICY.write().map_err(|_| "network policy lock poisoned")?;
    policy.generation = policy.generation.wrapping_add(1);
    policy.proxy = proxy;
    Ok(())
}

pub(crate) fn policy() -> Policy {
    POLICY.read().expect("network policy lock").clone()
}

impl Policy {
    #[cfg(not(target_os = "windows"))]
    pub(crate) fn configure(&self, builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
        builder
    }

    #[cfg(target_os = "windows")]
    pub(crate) fn configure(&self, builder: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
        let builder = builder.no_proxy();
        match &self.proxy {
            Some(proxy) => builder.proxy(proxy.clone()),
            None => builder,
        }
    }
    #[cfg(target_os = "linux")]
    pub(crate) fn configure_blocking(
        &self,
        builder: reqwest::blocking::ClientBuilder,
    ) -> reqwest::blocking::ClientBuilder {
        builder
    }

    #[cfg(target_os = "windows")]
    pub(crate) fn configure_blocking(
        &self,
        builder: reqwest::blocking::ClientBuilder,
    ) -> reqwest::blocking::ClientBuilder {
        let builder = builder.no_proxy();
        match &self.proxy {
            Some(proxy) => builder.proxy(proxy.clone()),
            None => builder,
        }
    }
}

pub(crate) struct ClientCache<T>(Mutex<Option<(u64, T)>>);
impl<T: Clone> ClientCache<T> {
    pub(crate) const fn new() -> Self {
        Self(Mutex::new(None))
    }
    pub(crate) fn get(
        &self,
        build: impl FnOnce(&Policy) -> Result<T, String>,
    ) -> Result<T, String> {
        // Keep publication and cache construction ordered across a core restart.
        let policy = POLICY.read().map_err(|_| "network policy lock poisoned")?;
        let mut cache = self
            .0
            .lock()
            .map_err(|_| "network client cache lock poisoned")?;
        if let Some((generation, client)) = cache.as_ref() {
            if *generation == policy.generation {
                return Ok(client.clone());
            }
        }
        let client = build(&policy)?;
        *cache = Some((policy.generation, client.clone()));
        Ok(client)
    }
}
