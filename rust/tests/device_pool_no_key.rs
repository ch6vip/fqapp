//! An encrypted pool file must never be *silently* overwritten with plaintext.
//!
//! Runs in its own test-process: it needs the process-global pool key to be
//! unprovisioned, which no other pool test can arrange once a key is set.

mod common;

use common::{MockReply, MockUpstream, TempDir};
use fqapi_core::device::pool_crypto;
use fqapi_core::device::DevicePool;

/// From rust/testdata/device_vectors.json: a registerkey response payload that
/// decrypts to `SECRETKEY_16byte` under the reference implementation.
const REGISTERKEY_INPUT_B64: &str =
    "ABEiM0RVZneImaq7zN3u//NnA1PPLklvy0VWJ2Qnd45A/zarUCjsToTdr+Zm34ab";

/// Encrypted-looking bytes: the magic prefix plus an opaque payload. Without a
/// key the pool cannot read them, which is all this test needs.
fn encrypted_looking_pool_bytes() -> Vec<u8> {
    let mut bytes = b"FQPOOL1".to_vec();
    bytes.extend_from_slice(&[0x11; 64]);
    bytes
}

#[tokio::test]
async fn an_encrypted_pool_is_backed_up_before_a_plaintext_save() {
    let upstream = MockUpstream::start(|recorded| match recorded.path.as_str() {
        "/service/2/device_register/" => MockReply::json(serde_json::json!({
            "device_id_str": "7276663560427471412",
            "install_id_str": "7276663560427471000",
        })),
        "/reading/crypt/registerkey" => MockReply::json(serde_json::json!({
            "data": { "key": REGISTERKEY_INPUT_B64 },
        })),
        _ => MockReply::status(200),
    })
    .await;

    let dir = TempDir::new("pool-no-key");
    let path = dir.join("device_pool.json");
    let encrypted = encrypted_looking_pool_bytes();
    std::fs::write(&path, &encrypted).expect("seed");

    // Dart provisions the key at startup; in this process it never did, so the
    // encrypted file cannot be decrypted and the pool starts empty.
    let pool = DevicePool::with_mock_origin(&path, upstream.origin.clone())
        .await
        .expect("pool");
    assert!(
        pool_crypto::pool_key().is_none(),
        "this test needs a process with no pool key provisioned"
    );
    assert_eq!(pool.count().await, 0);

    // Registering a usable device saves - in plaintext, because there is no
    // key. The encrypted bytes must survive as a backup instead of being
    // clobbered, which is what pool_crypto's contract promises.
    pool.refill(1).await.expect("refill");
    assert_eq!(pool.count().await, 1);

    let backups: Vec<String> = std::fs::read_dir(dir.path())
        .expect("read dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("device_pool.json.corrupt-"))
        .collect();
    assert_eq!(
        backups.len(),
        1,
        "exactly one backup of the encrypted pool: {backups:?}"
    );
    assert_eq!(
        std::fs::read(dir.join(&backups[0])).expect("backup"),
        encrypted,
        "the encrypted bytes must be preserved verbatim so a later session \
         that does have the key can still recover the identities"
    );

    let on_disk = std::fs::read(&path).expect("pool file");
    assert!(
        !pool_crypto::pool_file_is_encrypted(&on_disk),
        "the no-key fallback write is plaintext, as documented"
    );

    upstream.shutdown();
}
