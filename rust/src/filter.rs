//! Response filter configuration.
//!
//! The legacy design compiles a goja JavaScript runtime per route. Every route in
//! the shipped `filter.json` is `enabled:false`, and the migration contract
//! says a JS engine must not be pulled in for the first release. This module
//! therefore reads the configuration faithfully, applies nothing when every
//! route is disabled, and fails loudly (with the script names) when a route is
//! enabled - silently ignoring an enabled filter would change responses.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
struct RouteConfig {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    js: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
struct FileConfig {
    #[serde(default)]
    routes: std::collections::BTreeMap<String, RouteConfig>,
}

#[derive(Debug, Default)]
pub struct FilterManager {
    /// Routes that are enabled in configuration but unsupported in this build.
    pub enabled_unsupported: Vec<String>,
}

impl FilterManager {
    /// Reads filter.json. A missing file yields a no-op manager (like Go).
    pub fn load_with_base(config_path: &str, _base_dir: &str) -> Result<Self, String> {
        let data = match std::fs::read(config_path) {
            Ok(d) => d,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok(FilterManager::default())
            }
            Err(e) => return Err(format!("read filter.json: {e}")),
        };
        let cfg: FileConfig =
            serde_json::from_slice(&data).map_err(|e| format!("parse filter.json: {e}"))?;

        let mut enabled: Vec<String> = Vec::new();
        for (prefix, rc) in &cfg.routes {
            if rc.enabled && !rc.js.is_empty() {
                enabled.push(format!("{prefix} -> {}", rc.js));
            }
        }
        if !enabled.is_empty() {
            return Err(format!(
                "filter.json enables {} JS response filter(s) but this Rust core has no \
                 JavaScript runtime: {}",
                enabled.len(),
                enabled.join(", ")
            ));
        }
        Ok(FilterManager {
            enabled_unsupported: enabled,
        })
    }

    /// Longest-prefix route match. With no enabled routes this is always a
    /// pass-through, matching `Manager.Apply` on a nil manager.
    pub fn apply(&self, _path: &str, data: serde_json::Value) -> serde_json::Value {
        data
    }
}
