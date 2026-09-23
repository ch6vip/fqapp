//! Device pool contract tests: Go-compatible persistence, LRU selection,
//! concurrent access, and registration against a mock upstream.

mod common;

use common::{pool_json, MockReply, MockUpstream, TempDir};
use fqapi_core::device::DevicePool;

/// From rust/testdata/device_vectors.json: a registerkey response payload that
/// the pinned reference implementation decrypts to `SECRETKEY_16byte`.
const GO_REGISTERKEY_INPUT_B64: &str =
    "ABEiM0RVZneImaq7zN3u//NnA1PPLklvy0VWJ2Qnd45A/zarUCjsToTdr+Zm34ab";
const GO_REGISTERKEY_HEX: &str = "5345435245544B45595F313662797465";

#[tokio::test]
async fn loads_the_go_compatible_pool_json() {
    let dir = TempDir::new("pool-load");
    let path = dir.write("device_pool.json", &pool_json(3));

    let pool = DevicePool::new(&path).await.expect("pool loads");
    assert_eq!(pool.count().await, 3);

    let device = pool.get_by_id("0000000000000002").await.expect("device 2");
    assert_eq!(device.secret_key, format!("{:032x}", 2));
    assert_eq!(device.cdid, "cdid-2");
    assert_eq!(device.platform, "android");
    // Unknown ids are reported, not silently replaced.
    assert!(pool.get_by_id("missing").await.is_err());
}

#[tokio::test]
async fn missing_and_corrupt_pool_files_start_empty() {
    let dir = TempDir::new("pool-empty");
    let missing = dir.join("missing.json");
    let pool = DevicePool::new(&missing).await.expect("pool");
    assert_eq!(pool.count().await, 0);

    let corrupt = dir.write("corrupt.json", "{not json");
    let pool = DevicePool::new(&corrupt).await.expect("pool");
    assert_eq!(pool.count().await, 0);
}

#[tokio::test]
async fn get_rotates_through_the_least_recently_used_device() {
    let dir = TempDir::new("pool-lru");
    // pool_json orders last_used ascending, so device 0 is the LRU first.
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::new(&path).await.expect("pool");

    for expected in [0usize, 1, 2] {
        let device = pool.get().await.expect("device");
        assert_eq!(
            device.device_id,
            format!("{expected:016}"),
            "LRU rotation step {expected}"
        );
    }
}

#[tokio::test]
async fn concurrent_gets_do_not_corrupt_the_pool_file() {
    let dir = TempDir::new("pool-concurrent");
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::new(&path).await.expect("pool");

    let mut handles = Vec::new();
    for _ in 0..8 {
        let pool = pool.clone();
        handles.push(tokio::spawn(async move {
            pool.get().await.map(|d| d.device_id)
        }));
    }
    for handle in handles {
        assert!(handle.await.expect("join").is_ok(), "concurrent get failed");
    }

    // The file must still be valid Go-compatible JSON with every device intact.
    let text = std::fs::read_to_string(&path).expect("pool file");
    let parsed: serde_json::Value = serde_json::from_str(&text).expect("valid JSON after races");
    let devices = parsed["android"].as_array().expect("android array");
    assert_eq!(devices.len(), 5, "no device may be lost");
    for device in devices {
        assert!(device["use_count"].as_i64().unwrap_or(0) >= 1);
        assert!(!device["device_id"].as_str().unwrap_or("").is_empty());
    }
    assert!(parsed["last_update"].is_string());
}

#[tokio::test]
async fn refill_registers_a_device_and_decrypts_its_secret_key() {
    let upstream = MockUpstream::start(|recorded| match recorded.path.as_str() {
        "/service/2/device_register/" => MockReply::json(serde_json::json!({
            "device_id_str": "7276663560427471412",
            "install_id_str": "7276663560427471000",
        })),
        "/reading/crypt/registerkey" => MockReply::json(serde_json::json!({
            "data": { "key": GO_REGISTERKEY_INPUT_B64 },
        })),
        _ => MockReply::status(200),
    })
    .await;

    let dir = TempDir::new("pool-refill");
    let pool = DevicePool::with_mock_origin(dir.join("device_pool.json"), upstream.origin.clone())
        .await
        .expect("pool");

    // The registration flow intentionally waits 2s after app_alert_check, as in
    // the reference implementation; this is the one test that pays that cost.
    pool.refill(1).await.expect("refill");
    assert_eq!(pool.count().await, 1);

    let device = pool
        .get_by_id("7276663560427471412")
        .await
        .expect("new device");
    assert_eq!(
        device.secret_key, GO_REGISTERKEY_HEX,
        "the registerkey response must decrypt to the Go-vector secret key"
    );
    assert_eq!(device.install_id, "7276663560427471000");
    assert_eq!(device.status, "active");

    // Registration really hit the mock endpoints in order.
    let paths: Vec<String> = upstream.requests().iter().map(|r| r.path.clone()).collect();
    assert!(paths.contains(&"/service/2/device_register/".to_string()));
    assert!(paths.contains(&"/reading/crypt/registerkey".to_string()));
    upstream.shutdown();
}

#[tokio::test]
async fn a_retired_pool_refuses_further_writes() {
    let dir = TempDir::new("pool-retired");
    let path = dir.write("device_pool.json", &pool_json(5));
    let pool = DevicePool::new(&path).await.expect("pool");

    // Simulate the new core having written its own state.
    let marker = "{\"android\":[],\"last_update\":\"new-core\"}";
    std::fs::write(&path, marker).expect("overwrite");

    pool.retire().await;
    assert!(pool.is_retired());

    // Every path that would persist (get -> save) must leave the file alone.
    let device = pool
        .get()
        .await
        .expect("the retired pool is still readable");
    assert!(!device.device_id.is_empty());
    assert_eq!(
        std::fs::read_to_string(&path).expect("pool file"),
        marker,
        "a retired pool must not overwrite the new instance's device state"
    );
}
