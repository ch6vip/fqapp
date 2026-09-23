//! Filter configuration contract.
//!
//! The shipped `filter.json` disables all 15 routes and the Rust core links no
//! JavaScript engine, so the enabled-route path must fail loudly instead of
//! silently dropping a filter.

mod common;

use common::TempDir;
use fqapi_core::filter::FilterManager;
use serde_json::json;

#[test]
fn all_disabled_routes_are_a_pass_through() {
    let dir = TempDir::new("filter-off");
    let path = dir.write(
        "filter.json",
        &json!({
            "routes": {
                "/api/v1/books": {"enabled": false, "js": "filters/book.js"},
                "/api/v1/items": {"enabled": false, "js": "filters/item.js"},
            }
        })
        .to_string(),
    );
    let manager =
        FilterManager::load_with_base(&path.to_string_lossy(), &dir.path().to_string_lossy())
            .expect("disabled routes load cleanly");
    assert!(manager.enabled_unsupported.is_empty());

    let payload = json!({"code": 0, "data": {"item_data_list": []}});
    assert_eq!(
        manager.apply("/api/v1/books/1", payload.clone()),
        payload,
        "with no enabled route the payload must pass through untouched"
    );
}

#[test]
fn a_missing_config_is_a_no_op_manager() {
    let dir = TempDir::new("filter-missing");
    let missing = dir.join("filter.json");
    let manager =
        FilterManager::load_with_base(&missing.to_string_lossy(), &dir.path().to_string_lossy())
            .expect("a missing file is not an error");
    assert!(manager.enabled_unsupported.is_empty());
}

#[test]
fn an_enabled_route_fails_loudly_with_the_script_name() {
    let dir = TempDir::new("filter-on");
    let path = dir.write(
        "filter.json",
        &json!({
            "routes": {
                "/api/v1/books": {"enabled": false, "js": "filters/book.js"},
                "/api/v1/videos": {"enabled": true, "js": "filters/video.js"},
            }
        })
        .to_string(),
    );
    let error =
        FilterManager::load_with_base(&path.to_string_lossy(), &dir.path().to_string_lossy())
            .expect_err("an enabled route must not be ignored");
    assert!(
        error.contains("/api/v1/videos") && error.contains("filters/video.js"),
        "the error must name the route and the script: {error}"
    );
    assert!(
        error.contains("JavaScript") || error.contains("JS"),
        "the error must explain that no JS engine is linked: {error}"
    );
}

#[test]
fn malformed_config_is_reported() {
    let dir = TempDir::new("filter-bad");
    let path = dir.write("filter.json", "{not json");
    assert!(
        FilterManager::load_with_base(&path.to_string_lossy(), &dir.path().to_string_lossy())
            .is_err()
    );
}
