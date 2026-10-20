//! P1-2: the device-pool file is encrypted at rest once a key is
//! provisioned, migrates from plaintext on the next save, and an
//! undecryptable file is backed up (P2-14) instead of silently discarded.
//!
//! Runs in its own test-process: it provisions the process-global pool key.

mod common;

use common::{pool_json, TempDir};
use fqapi_core::device::pool_crypto;
use fqapi_core::device::DevicePool;

const KEY_A: [u8; 32] = [0xA5; 32];
const KEY_B: [u8; 32] = [0x5A; 32];

/// One sequential test: both scenarios share the process-global pool key,
///
/// so they must not run in parallel test threads.
#[tokio::test]
async fn pool_file_is_encrypted_at_rest_and_migrates_from_plaintext() {
    pool_file_is_encrypted_at_rest_and_migrates_from_plaintext_inner().await;
    undecryptable_pool_file_is_backed_up_and_starts_empty_inner().await;
}

async fn pool_file_is_encrypted_at_rest_and_migrates_from_plaintext_inner() {
    let dir = TempDir::new("pool-encrypted");
    let path = dir.join("device_pool.json");
    // Legacy plaintext seed.
    let seed = pool_json(2);
    dir.write("device_pool.json", &seed);

    pool_crypto::provision_pool_key(KEY_A.to_vec()).expect("provision");
    let pool = DevicePool::new(&path).await.expect("pool loads plaintext");
    assert_eq!(pool.count().await, 2);
    // A save migrates the file to encrypted.
    pool.refill(0).await.expect("refill saves");
    let on_disk = std::fs::read(&path).expect("pool file");
    assert!(pool_crypto::pool_file_is_encrypted(&on_disk));
    assert!(!String::from_utf8_lossy(&on_disk).contains("android"));

    // A fresh pool instance reads the encrypted file back.
    let pool2 = DevicePool::new(&path).await.expect("pool loads encrypted");
    assert_eq!(pool2.count().await, 2);
    let device = pool2.get_by_id("0000000000000001").await.expect("device 1");
    assert_eq!(device.secret_key, format!("{:032x}", 1));
}

async fn undecryptable_pool_file_is_backed_up_and_starts_empty_inner() {
    let dir = TempDir::new("pool-wrongkey");
    let path = dir.join("device_pool.json");
    dir.write("device_pool.json", &pool_json(2));

    pool_crypto::provision_pool_key(KEY_A.to_vec()).expect("provision A");
    let pool = DevicePool::new(&path).await.expect("pool");
    pool.refill(0).await.expect("refill encrypts");

    // A different key cannot read the file: pool starts empty, the
    // encrypted bytes survive as a .corrupt-<ts> backup.
    pool_crypto::provision_pool_key(KEY_B.to_vec()).expect("provision B");
    let pool2 = DevicePool::new(&path).await.expect("pool");
    assert_eq!(pool2.count().await, 0);

    let backups: Vec<_> = std::fs::read_dir(dir.path())
        .expect("read dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("device_pool.json.corrupt-"))
        .collect();
    assert_eq!(backups.len(), 1, "exactly one backup: {backups:?}");
    let backup_bytes = std::fs::read(dir.join(&backups[0])).expect("backup");
    assert!(pool_crypto::pool_file_is_encrypted(&backup_bytes));
}
