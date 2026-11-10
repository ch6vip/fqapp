//! Runtime configuration (mirrors config.json).

use serde::{Deserialize, Deserializer};

/// Accept `"65132"` and a bare `65132` alike.
///
/// A version number is the most natural thing to type as a JSON number, and a
/// type error here is fatal: `Config::load` returns `Err`, `init_core` fails and
/// the whole backend never starts — for a value that is completely unambiguous.
///
/// A JSON number is rendered through its numeric value, not through Rust's
/// `Display`: the latter prints `71332.0` for `71332.0`, and a version code
/// that reached the upstream with a decimal point would be a version code
/// nobody asked for. JSON says `71332.0`, `1e3` and `71332` are the same
/// number, so an integral value is rendered as an integer and only a real
/// fraction keeps its decimal form.
fn stringish<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    Ok(match value {
        serde_json::Value::String(text) => text,
        serde_json::Value::Number(number) => {
            if let Some(integer) = number.as_i64() {
                integer.to_string()
            } else if let Some(integer) = number.as_u64() {
                integer.to_string()
            } else if let Some(float) = number.as_f64() {
                // The exact-integer range of an i64; beyond it the float is not
                // a version code anyway, so it keeps its own spelling.
                if float.is_finite() && float.fract() == 0.0 && float.abs() <= i64::MAX as f64 {
                    format!("{}", float as i64)
                } else {
                    serde_json::to_string(&number).unwrap_or_else(|_| number.to_string())
                }
            } else {
                number.to_string()
            }
        }
        serde_json::Value::Bool(flag) => flag.to_string(),
        serde_json::Value::Null => String::new(),
        other => {
            return Err(<D::Error as serde::de::Error>::custom(format!(
                "expected a string, got {other}"
            )))
        }
    })
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AntiCrawler {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub redirect_url: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Admin {
    #[serde(default)]
    pub token: String,
    #[serde(default)]
    pub update_server_url: String,
}

/// Upstream identity: the parameters Fanqie changes now and then (app version,
/// user-agent) without changing any protocol.
///
/// These used to be hard-coded in `device/register.rs`, which meant every upstream
/// bump needed a release. They are **parameters**, not logic: when upstream
/// changes the signing algorithm or the registration flow this struct does not
/// help and a release is still required. Empty fields fall back to the values
/// that were hard-coded before, so an absent `upstream` section changes nothing.
///
/// Scope: **only the device-registration requests** read this. The book,
/// directory, search and video endpoints carry their own hard-coded
/// `version_code=65132&version_name=6.5.1.32...` query suffixes
/// (`endpoints/*.rs`), and generic upstream calls use
/// `upstream::client::DEFAULT_USER_AGENT`. Changing those still means code.
#[derive(Debug, Clone, Default)]
pub struct UpstreamIdentity {
    pub version_name: String,
    pub version_code: String,
    pub manifest_version_code: String,
    pub update_version_code: String,
    /// Optional override for the whole UA. `{manifest_version_code}` (or its
    /// alias `{version_code}`), `{os_version}` and `{device_type}` are
    /// substituted; empty keeps the built-in template.
    pub user_agent: String,
}

/// The upstream section must be a JSON **object**.
///
/// A derived `Deserialize` would accept a JSON array here: serde fills a
/// struct's fields positionally from a sequence, so `"upstream": [1, 2]`
/// silently became `version_name = "1"`, `version_code = "2"`. That identity
/// then went out to the upstream `device_register` endpoint looking like a
/// real - but wrong - app version, with nothing logged. `null` failed for the
/// opposite reason: `#[serde(default)]` only covers a *missing* field, not an
/// explicit `null`, so the whole backend refused to start over a section the
/// documentation calls "leave it out and you get the defaults".
///
/// So the section shape is checked here, explicitly: only an object (or an
/// explicit `null`, read as "not configured") is accepted, and every other
/// shape is a configuration error that stops `Config::load`.
impl<'de> Deserialize<'de> for UpstreamIdentity {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Fields {
            #[serde(default, deserialize_with = "stringish")]
            version_name: String,
            #[serde(default, deserialize_with = "stringish")]
            version_code: String,
            #[serde(default, deserialize_with = "stringish")]
            manifest_version_code: String,
            #[serde(default, deserialize_with = "stringish")]
            update_version_code: String,
            #[serde(default, deserialize_with = "stringish")]
            user_agent: String,
        }

        match serde_json::Value::deserialize(deserializer)? {
            serde_json::Value::Object(map) => {
                let fields: Fields = serde_json::from_value(serde_json::Value::Object(map))
                    .map_err(<D::Error as serde::de::Error>::custom)?;
                let identity = Self {
                    version_name: fields.version_name,
                    version_code: fields.version_code,
                    manifest_version_code: fields.manifest_version_code,
                    update_version_code: fields.update_version_code,
                    user_agent: fields.user_agent,
                };
                // Half a version is a configuration error, like the other
                // malformed shapes: the device would report two releases at
                // once. It is rejected here rather than warned about because
                // the warning would only be visible on Android - the desktop
                // build installs no logger, so the log macros are no-ops
                // there - and a silent identity is exactly what this section
                // must not produce.
                if let Some(note) = identity.partial_version_note() {
                    return Err(<D::Error as serde::de::Error>::custom(note));
                }
                Ok(identity)
            }
            // An explicit null means "not configured", the same as omitting the
            // section. `#[serde(default)]` cannot express this on its own.
            serde_json::Value::Null => Ok(Self::default()),
            other => Err(<D::Error as serde::de::Error>::custom(format!(
                "the upstream section must be a JSON object, got {other}"
            ))),
        }
    }
}

impl UpstreamIdentity {
    const DEFAULT_VERSION_NAME: &str = "6.5.1.32";
    const DEFAULT_VERSION_CODE: &str = "65132";

    /// Fill empty fields with the pre-externalisation defaults, and keep the
    /// version fields consistent with each other.
    ///
    /// The three `*_version_code` fields are three views of one upstream
    /// release, so filling each one independently produced self-contradicting
    /// identities: setting only `version_code` left the registration header
    /// carrying the new code next to the old manifest and update codes, and
    /// the user agent ended up describing a version the body did not.
    ///
    /// The rule is therefore: an explicitly configured code always wins, and a
    /// code that was left out follows `version_code` (the field that names the
    /// release) rather than jumping back to the built-in default. Configuring
    /// nothing still yields exactly the pre-externalisation constants.
    pub fn resolved(&self) -> Self {
        let trimmed = |value: &str| value.trim().to_string();
        let configured = |value: &str| !value.trim().is_empty();

        let version_code = if configured(&self.version_code) {
            trimmed(&self.version_code)
        } else {
            Self::DEFAULT_VERSION_CODE.to_string()
        };
        // The codes follow `version_code` unless they were set explicitly, so
        // one release number moves all of them together.
        let code_or_follow = |value: &str| {
            if configured(value) {
                trimmed(value)
            } else {
                version_code.clone()
            }
        };

        Self {
            version_name: if configured(&self.version_name) {
                trimmed(&self.version_name)
            } else {
                Self::DEFAULT_VERSION_NAME.to_string()
            },
            version_code: version_code.clone(),
            manifest_version_code: code_or_follow(&self.manifest_version_code),
            update_version_code: code_or_follow(&self.update_version_code),
            user_agent: trimmed(&self.user_agent),
        }
    }

    /// Warns about a version that was only half configured.
    ///
    /// `version_name` (`7.1.3.32`) and `version_code` (`71332`) are two
    /// spellings of one release, but there is no rule that derives one from
    /// the other: dropping the dots happens to hold for most of the pairs in
    /// this codebase (`6.5.1.32` -> `65132`), but not for all of them
    /// (`15.8.0` -> `150800`). Deriving one would mean guessing, and a
    /// guessed version number is an upstream identity that looks right and is
    /// wrong.
    ///
    /// So nothing is derived. What this reports is the case the user can act
    /// on: they changed one of the two spellings and left the other at the
    /// previous release, which makes the device describe two versions at once.
    pub fn partial_version_note(&self) -> Option<String> {
        let has_name = !self.version_name.trim().is_empty();
        let has_code = !self.version_code.trim().is_empty();
        match (has_name, has_code) {
            (true, false) => Some(
                "the upstream section sets version_name but not version_code; \
                 they are two spellings of the same release and must be set together"
                    .to_string(),
            ),
            (false, true) => Some(
                "the upstream section sets version_code but not version_name; \
                 they are two spellings of the same release and must be set together"
                    .to_string(),
            ),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct NetworkProxy {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub url: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub network_proxy: NetworkProxy,
    #[serde(default)]
    pub algorithm_type: String,
    #[serde(default)]
    pub zwsm: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub anti_crawler: AntiCrawler,
    #[serde(default)]
    pub admin: Admin,
    #[serde(default)]
    pub upstream: UpstreamIdentity,
}

impl Config {
    pub fn load(path: &str) -> Result<Self, String> {
        let data = std::fs::read(path).map_err(|e| format!("read config {path}: {e}"))?;
        let mut c: Config =
            serde_json::from_slice(&data).map_err(|e| format!("parse config {path}: {e}"))?;
        if c.port == 0 {
            c.port = 18921;
        }
        Ok(c)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `config.json` is hand-edited: a fat-fingered number must not stop the
    /// backend from starting (`Config::load` failing takes `init_core` with it).
    #[test]
    fn numeric_and_boolean_values_are_accepted_as_strings() {
        let config: Config = serde_json::from_str(
            r#"{"port":18921,"upstream":{"version_code":71332,"version_name":7.1,"user_agent":true}}"#,
        )
        .expect("numbers and booleans must not fail the whole load");
        assert_eq!(config.upstream.version_code, "71332");
        assert_eq!(config.upstream.version_name, "7.1");
        assert_eq!(config.upstream.user_agent, "true");
    }

    #[test]
    fn an_absent_upstream_section_falls_back_to_the_previous_constants() {
        let config: Config = serde_json::from_str(r#"{"algorithm_type":"8404","port":0}"#)
            .expect("old configs must still parse");
        let identity = config.upstream.resolved();
        assert_eq!(identity.version_name, "6.5.1.32");
        assert_eq!(identity.version_code, "65132");
        assert_eq!(identity.manifest_version_code, "65132");
        assert_eq!(identity.update_version_code, "65132");
        assert!(
            identity.user_agent.is_empty(),
            "empty means the built-in template"
        );
    }

    /// The section shape is checked explicitly: a JSON array would otherwise be
    /// read positionally into the struct's fields and produce a plausible but
    /// wrong identity (`version_code = "2"`) that nothing logged.
    #[test]
    fn an_array_upstream_section_is_a_configuration_error() {
        let error = serde_json::from_str::<Config>(r#"{"port":18921,"upstream":[1,2]}"#)
            .expect_err("an array must not be read as a positional field list");
        assert!(
            error.to_string().contains("must be a JSON object"),
            "got {error}"
        );
    }

    /// `null` reads as "not configured", the same as omitting the section:
    /// `#[serde(default)]` alone would have failed the whole load.
    #[test]
    fn a_null_upstream_section_reads_as_not_configured() {
        let config: Config = serde_json::from_str(r#"{"port":18921,"upstream":null}"#)
            .expect("an explicit null must not stop the backend from starting");
        let identity = config.upstream.resolved();
        assert_eq!(identity.version_code, "65132");
        assert_eq!(identity.version_name, "6.5.1.32");
    }

    /// A JSON number keeps its numeric value: `71332.0` must not reach the
    /// upstream as "71332.0", and `1e3` must not become "1000.0".
    #[test]
    fn numbers_keep_their_json_spelling() {
        let config: Config = serde_json::from_str(
            r#"{"port":18921,"upstream":{"version_name":"7.1.3.32","version_code":71332.0,"manifest_version_code":1e3}}"#,
        )
        .expect("numbers must not fail the whole load");
        assert_eq!(config.upstream.version_code, "71332");
        assert_eq!(config.upstream.manifest_version_code, "1000");
    }

    /// A genuine fraction is not a version code, but it must not be rounded
    /// into a plausible-looking integer either.
    #[test]
    fn a_fractional_number_keeps_its_fraction() {
        let config: Config = serde_json::from_str(
            r#"{"port":18921,"upstream":{"version_name":7.1,"version_code":71332}}"#,
        )
        .expect("numbers must not fail the whole load");
        assert_eq!(config.upstream.version_name, "7.1");
    }

    /// The configuration that actually ships in the APK must keep parsing.
    /// The upstream section is strict about its shape and its field names, so
    /// this is the guard that a stricter parser does not brick the release.
    #[test]
    fn the_shipped_config_json_still_parses() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../assets/config/config.json");
        let body = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
        let config: Config =
            serde_json::from_str(&body).unwrap_or_else(|e| panic!("parse {path}: {e}"));
        assert_ne!(config.port, 0, "the shipped config must declare a port");
        // The shipped config configures no upstream identity, so the built-in
        // constants apply.
        assert_eq!(config.upstream.resolved().version_code, "65132");
    }

    /// A mistyped field name must not be silently ignored: `useragent` instead
    /// of `user_agent` would leave the user agent at its built-in template and
    /// the change would look like it had no effect, with nothing reported.
    #[test]
    fn a_mistyped_field_is_a_configuration_error() {
        for (label, body) in [
            (
                "useragent",
                r#"{"port":18921,"upstream":{"useragent":"ua/1"}}"#,
            ),
            (
                "versioncode",
                r#"{"port":18921,"upstream":{"versioncode":71332}}"#,
            ),
            (
                "extra",
                r#"{"port":18921,"upstream":{"version_code":71332,"notes":"x"}}"#,
            ),
        ] {
            let error = serde_json::from_str::<Config>(body)
                .expect_err("an unknown field must not be ignored");
            assert!(
                error.to_string().contains("unknown field"),
                "{label}: got {error}"
            );
        }
    }

    /// The three codes are three views of one release: configuring one of them
    /// must move the others, instead of leaving the new code next to the old
    /// manifest and update codes.
    #[test]
    fn an_unset_code_follows_the_configured_version_code() {
        let config: Config = serde_json::from_str(
            r#"{"port":18921,"upstream":{"version_name":"7.1.3.32","version_code":71332}}"#,
        )
        .expect("a complete section must parse");
        let identity = config.upstream.resolved();
        assert_eq!(identity.version_code, "71332");
        assert_eq!(identity.manifest_version_code, "71332");
        assert_eq!(identity.update_version_code, "71332");
    }

    /// An explicitly configured code still wins over the one it would follow.
    #[test]
    fn an_explicit_code_wins_over_the_following_rule() {
        let config: Config = serde_json::from_str(
            r#"{"port":18921,"upstream":{"version_name":"7.1.3.32","version_code":71332,"update_version_code":80000}}"#,
        )
        .expect("a complete section must parse");
        let identity = config.upstream.resolved();
        assert_eq!(identity.version_code, "71332");
        assert_eq!(identity.manifest_version_code, "71332");
        assert_eq!(identity.update_version_code, "80000");
    }

    /// Setting only one of the two spellings of the release is a configuration
    /// error, not a warning: the device would report two releases at once.
    /// `version_code` cannot be derived from `version_name` in general
    /// (`15.8.0` -> `150800`, not `1580`), so there is nothing to fill in.
    #[test]
    fn a_half_configured_version_is_a_configuration_error() {
        for (label, body) in [
            (
                "name only",
                r#"{"port":18921,"upstream":{"version_name":"7.1.3.32"}}"#,
            ),
            (
                "code only",
                r#"{"port":18921,"upstream":{"version_code":"71332"}}"#,
            ),
        ] {
            let error = serde_json::from_str::<Config>(body)
                .expect_err("half a version must not be accepted");
            let text = error.to_string();
            assert!(
                text.contains("version_code") || text.contains("version_name"),
                "{label}: got {text}"
            );
        }
    }

    /// A complete configuration, or none at all, is accepted.
    #[test]
    fn a_complete_or_absent_version_is_accepted() {
        let complete: Config = serde_json::from_str(
            r#"{"port":18921,"upstream":{"version_name":"7.1.3.32","version_code":"71332"}}"#,
        )
        .expect("a complete section must parse");
        assert!(complete.upstream.partial_version_note().is_none());

        let absent: Config =
            serde_json::from_str(r#"{"port":18921}"#).expect("an absent section must parse");
        assert!(absent.upstream.partial_version_note().is_none());

        let explicit_null: Config = serde_json::from_str(r#"{"port":18921,"upstream":null}"#)
            .expect("an explicit null must parse");
        assert!(explicit_null.upstream.partial_version_note().is_none());
    }

    /// Resolving twice must not change anything.
    ///
    /// The identity is resolved when it is published, and again when a device
    /// is built from it. If the second pass could change a value, the version
    /// recorded in the device pool would not be the version the pool compares
    /// against, and every device would be retired on the next start.
    #[test]
    fn resolving_twice_is_the_same_as_resolving_once() {
        for identity in [
            UpstreamIdentity::default(),
            UpstreamIdentity {
                version_code: "71332".into(),
                ..UpstreamIdentity::default()
            },
            UpstreamIdentity {
                version_name: "7.1.3.32".into(),
                ..UpstreamIdentity::default()
            },
            UpstreamIdentity {
                manifest_version_code: "800".into(),
                ..UpstreamIdentity::default()
            },
            UpstreamIdentity {
                version_code: "  900  ".into(),
                ..UpstreamIdentity::default()
            },
        ] {
            let once = identity.resolved();
            let twice = once.resolved();
            assert_eq!(once.version_code, twice.version_code);
            assert_eq!(once.manifest_version_code, twice.manifest_version_code);
            assert_eq!(once.update_version_code, twice.update_version_code);
            assert_eq!(once.version_name, twice.version_name);
            assert_eq!(once.user_agent, twice.user_agent);
        }
    }
}
