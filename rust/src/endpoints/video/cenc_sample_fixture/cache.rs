use super::*;

/// Cache state detection and the key sidecar roundtrip the serve path
/// depends on: encrypted stays detectable, a decrypted copy reads as
/// clear, garbage is unknown (and therefore never deleted blindly).
#[test]
fn cache_state_detection_and_sidecar_roundtrip() {
    let f = fixture();
    let c = &f["cenc"];
    let encrypted = b64(c, "full_sample_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    let mut plaintext = encrypted.clone();
    decrypt_cenc_mp4(&mut plaintext, &key).expect("decrypt");

    let dir = p17_temp_dir("state");
    let enc_path = dir.join("enc.mp4");
    std::fs::write(&enc_path, &encrypted).expect("write encrypted");
    assert_eq!(cache_cenc_state(&enc_path), CacheCencState::Encrypted);
    assert!(read_key_sidecar(&enc_path).is_none());
    write_key_sidecar(&enc_path, &key).expect("write sidecar");
    assert_eq!(
        read_key_sidecar(&enc_path).expect("sidecar"),
        key,
        "sidecar must roundtrip the content key"
    );

    let plain_path = dir.join("plain.mp4");
    std::fs::write(&plain_path, &plaintext).expect("write plaintext");
    assert_eq!(cache_cenc_state(&plain_path), CacheCencState::Clear);

    let junk_path = dir.join("junk.mp4");
    std::fs::write(&junk_path, b"not an mp4 at all").expect("write junk");
    assert_eq!(cache_cenc_state(&junk_path), CacheCencState::Unknown);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The one-time migration (user decision 2026-10-25): plaintext cache
/// files from the old in-place decrypt are removed on first run;
/// encrypted entries, unparseable files and non-video files stay; the
/// marker makes later runs no-ops except for pending retries, which
/// re-test the file before deleting anything.
#[test]
fn migration_removes_plaintext_and_keeps_the_rest() {
    let f = fixture();
    let c = &f["cenc"];
    let encrypted = b64(c, "full_sample_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    let mut plaintext = encrypted.clone();
    decrypt_cenc_mp4(&mut plaintext, &key).expect("decrypt");

    let dir = p17_temp_dir("migration");
    std::fs::write(dir.join("enc.mp4"), &encrypted).expect("enc");
    std::fs::write(dir.join("plain.mp4"), &plaintext).expect("plain");
    std::fs::write(dir.join("plain.mp4.key"), b"deadbeef").expect("plain sidecar");
    std::fs::write(dir.join("junk.mp4"), b"not an mp4").expect("junk");
    std::fs::write(dir.join("note.txt"), &plaintext).expect("note");
    std::fs::write(dir.join("clip.ts"), &plaintext).expect("ts");

    migrate_plaintext_video_cache(&dir);
    assert!(!dir.join("plain.mp4").exists(), "plaintext cache removed");
    assert!(
        !dir.join("plain.mp4.key").exists(),
        "its sidecar goes with it"
    );
    assert!(dir.join("enc.mp4").exists(), "encrypted cache kept");
    assert!(dir.join("junk.mp4").exists(), "unparseable file kept");
    assert!(dir.join("note.txt").exists(), "non-video file kept");
    assert!(
        dir.join("clip.ts").exists(),
        ".ts never went through the MP4 decrypt"
    );
    assert!(dir.join(CACHE_FORMAT_MARKER).exists(), "marker written");

    // Second run is a no-op.
    migrate_plaintext_video_cache(&dir);
    assert!(dir.join("enc.mp4").exists());

    // A pending retry removes a plaintext file that shows up later…
    std::fs::write(dir.join("late.mp4"), &plaintext).expect("late");
    std::fs::write(dir.join(CACHE_FORMAT_PENDING), b"late.mp4\n").expect("pending");
    migrate_plaintext_video_cache(&dir);
    assert!(!dir.join("late.mp4").exists(), "pending plaintext removed");
    assert!(
        !dir.join(CACHE_FORMAT_PENDING).exists(),
        "pending list cleared once empty"
    );

    // …but re-tests first: a name since reused by an encrypted entry is
    // kept, not deleted.
    std::fs::write(dir.join("reused.mp4"), &encrypted).expect("reused");
    std::fs::write(dir.join(CACHE_FORMAT_PENDING), b"reused.mp4\n").expect("pending");
    migrate_plaintext_video_cache(&dir);
    assert!(
        dir.join("reused.mp4").exists(),
        "reused encrypted name kept"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// P0-1: the fixed-size `stsz` branch used to allocate one `usize` per
/// declared sample with no bound, so a box claiming billions of samples
/// could OOM the process from 8 header bytes. It must reject counts
/// whose samples cannot fit in the file, while still accepting sane
/// fixed-size boxes.
#[test]
fn stsz_fixed_size_branch_rejects_absurd_sample_count() {
    fn stsz_box(sample_size: u32, sample_count: u32, file_len: usize) -> (Vec<u8>, Mp4Box) {
        let mut data = vec![0u8; file_len.max(20)];
        data[12..16].copy_from_slice(&sample_size.to_be_bytes());
        data[16..20].copy_from_slice(&sample_count.to_be_bytes());
        (
            data,
            Mp4Box {
                off: 0,
                size: 20,
                header: 8,
                typ: *b"stsz",
            },
        )
    }

    // Absurd count: would previously allocate ~32 GiB of `usize`s.
    let (data, b) = stsz_box(1024, u32::MAX, 20);
    assert!(
        parse_stsz(&data, b).is_empty(),
        "sample_count whose samples cannot fit in the file must be rejected"
    );
    // Count above the absolute cap, even with 1-byte samples.
    let (data, b) = stsz_box(1, MAX_STSZ_SAMPLES as u32 + 1, 20);
    assert!(
        parse_stsz(&data, b).is_empty(),
        "sample_count above MAX_STSZ_SAMPLES must be rejected"
    );
    // Product overflow: 2 * u32::MAX samples of u32::MAX bytes.
    let (data, b) = stsz_box(u32::MAX, 2, 20);
    assert!(
        parse_stsz(&data, b).is_empty(),
        "overflowing sample_count * sample_size must be rejected"
    );
    // Sane fixed-size box still parses.
    let (data, b) = stsz_box(100, 3, 320);
    assert_eq!(parse_stsz(&data, b), vec![100, 100, 100]);
}
