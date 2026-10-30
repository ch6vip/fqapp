//! Offline contract for CENC sample decryption (video.rs).
//!
//! The MP4 comes from the offline fixture generator: a minimal
//! `moov/trak/mdia/minf/stbl` with `stsd(encv)`, `stsz`, `stsc`, `stco`,
//! `senc` and `tenc`, plus an encrypted `mdat`. It was encrypted by an
//! independent AES-CTR implementation and stored the plaintext samples, so
//! this test compares the decryption against data the Rust side never
//! produced.

use super::*;

const FIXTURE: &str = include_str!("../../../testdata/cenc_sample_fixture.json");

fn fixture() -> serde_json::Value {
    serde_json::from_str(FIXTURE).expect("cenc_sample_fixture.json")
}

fn b64(f: &serde_json::Value, key: &str) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(f[key].as_str().expect(key))
        .expect("base64 fixture")
}

fn plain_samples(f: &serde_json::Value, key: &str) -> Vec<Vec<u8>> {
    f[key]
        .as_array()
        .expect(key)
        .iter()
        .map(|v| {
            base64::engine::general_purpose::STANDARD
                .decode(v.as_str().expect("sample"))
                .expect("base64 sample")
        })
        .collect()
}

/// The encrypted `mdat` starts at the offset the generator reported for
/// that case (the two cases have different moov sizes).
fn encrypted_region(file: &[u8], f: &serde_json::Value, key: &str) -> Vec<u8> {
    let off = f[key].as_u64().expect(key) as usize;
    file[off..].to_vec()
}

#[test]
fn detects_encrypted_tracks_and_rewrites_the_sample_entry() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    assert!(mp4_needs_cenc_decrypt(&file), "encv must be detected");

    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");

    // encv -> hvc1 and sinf -> free, so a re-run must no longer see it as
    // encrypted (that is what makes the call idempotent).
    assert!(
        !mp4_needs_cenc_decrypt(&file),
        "the sample entry must be rewritten to a clear one"
    );
}

#[test]
fn decrypts_every_whole_encrypted_sample_with_the_go_plaintext() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let expected = plain_samples(c, "full_sample_plain_b64");
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

    // The samples are laid out contiguously in mdat, in stsz order.
    let before = encrypted_region(&file, c, "full_mdat_offset");
    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");
    let after = encrypted_region(&file, c, "full_mdat_offset");

    let mut cursor = 0usize;
    for (i, want) in expected.iter().enumerate() {
        let got = &after[cursor..cursor + want.len()];
        assert_eq!(got, want.as_slice(), "sample {i}");
        // Go's ciphertext must differ from the plaintext for a non-trivial
        // sample, otherwise the comparison proves nothing.
        assert_ne!(
            &before[cursor..cursor + want.len()],
            want.as_slice(),
            "sample {i} was not actually encrypted"
        );
        cursor += want.len();
    }
    assert_eq!(cursor, after.len(), "all samples covered");
}

#[test]
fn decrypts_subsample_encrypted_payloads_and_keeps_the_clear_header() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "subsample_b64");
    let expected = plain_samples(c, "subsample_plain_b64");
    let clear_head = c["subsample_clear_head"].as_u64().unwrap() as usize;
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();

    decrypt_cenc_mp4(&mut file, &key).expect("decrypt");
    let after = encrypted_region(&file, c, "subsample_mdat_offset");

    let mut cursor = 0usize;
    for (i, want) in expected.iter().enumerate() {
        let got = &after[cursor..cursor + want.len()];
        assert_eq!(got, want.as_slice(), "sample {i}");
        // senc flags=2 marks the head as clear: it must survive untouched.
        assert_eq!(
            &got[..clear_head],
            &want[..clear_head],
            "sample {i} clear head"
        );
        cursor += want.len();
    }
}

#[test]
fn a_wrong_key_produces_different_bytes_and_a_bad_length_is_rejected() {
    let f = fixture();
    let c = &f["cenc"];
    let mut file = b64(c, "full_sample_b64");
    let original = file.clone();
    let expected = plain_samples(c, "full_sample_plain_b64");

    assert!(decrypt_cenc_mp4(&mut file.clone(), &[0u8; 7]).is_err());
    decrypt_cenc_mp4(&mut file, &[0xAAu8; 16]).expect("wrong key still decrypts");
    let after = encrypted_region(&file, c, "full_mdat_offset");
    assert_ne!(
        &after[..expected[0].len()],
        expected[0].as_slice(),
        "a wrong key must not reproduce the Go plaintext"
    );
    assert_ne!(file, original, "the wrong key must have changed the bytes");
}

/// P1-7: the cache file now stays encrypted on disk and the decrypted
/// view is produced per served range. Applying the index range by range
/// — unaligned probes, block-straddling slices, and a sequential
/// small-chunk pass like the streaming body's — must reproduce the
/// whole-file decrypt byte for byte.
#[test]
fn served_ranges_match_the_whole_file_decrypt() {
    let f = fixture();
    let c = &f["cenc"];
    let key = hex::decode(c["key_hex"].as_str().unwrap()).unwrap();
    for case in ["full_sample_b64", "subsample_b64"] {
        let encrypted = b64(c, case);
        let mut whole = encrypted.clone();
        decrypt_cenc_mp4(&mut whole, &key).expect("whole decrypt");
        assert_ne!(whole, encrypted, "{case} must actually be encrypted");

        let index = build_cenc_index(&encrypted, 0, encrypted.len() as u64)
            .expect("index build")
            .expect("encrypted fixture must produce an index");
        let mut probes: Vec<(usize, usize)> = vec![(0, encrypted.len()), (0, 28)];
        let mut off = 0;
        while off < encrypted.len() {
            probes.push((off, (encrypted.len() - off).min(37)));
            off += 37;
        }
        for (off, len) in probes {
            let mut buf = encrypted[off..off + len].to_vec();
            apply_cenc_index(&mut buf, off as u64, &index, &key).expect("apply");
            assert_eq!(buf, whole[off..off + len], "{case} range {off}+{len}");
        }
        let mut streamed = Vec::with_capacity(encrypted.len());
        let mut pos = 0usize;
        while pos < encrypted.len() {
            let take = (encrypted.len() - pos).min(7);
            let mut buf = encrypted[pos..pos + take].to_vec();
            apply_cenc_index(&mut buf, pos as u64, &index, &key).expect("chunk apply");
            streamed.extend_from_slice(&buf);
            pos += take;
        }
        assert_eq!(streamed, whole, "{case} chunked stream");
    }
}

fn p17_temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-p17-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

/// The serve path builds its index from the moov box alone; that index
/// must agree with the one built from the whole file.
#[test]
fn index_from_moov_slice_matches_whole_file_index() {
    let f = fixture();
    let c = &f["cenc"];
    let encrypted = b64(c, "full_sample_b64");
    let dir = p17_temp_dir("moov");
    let path = dir.join("sample.mp4");
    std::fs::write(&path, &encrypted).expect("write fixture");

    let (moov_off, moov) = read_moov_bytes(&path).expect("moov must be readable");
    assert_eq!(moov_off, 28, "fixture moov offset");
    let from_moov = build_cenc_index(&moov, moov_off, encrypted.len() as u64)
        .expect("build from moov")
        .expect("index from moov");
    let from_file = build_cenc_index(&encrypted, 0, encrypted.len() as u64)
        .expect("build from file")
        .expect("index from file");
    assert_eq!(from_moov.patches.len(), from_file.patches.len());
    for (a, b) in from_moov.patches.iter().zip(&from_file.patches) {
        assert_eq!((a.off, &a.bytes), (b.off, &b.bytes), "patch");
    }
    assert_eq!(from_moov.ranges.len(), from_file.ranges.len());
    for (a, b) in from_moov.ranges.iter().zip(&from_file.ranges) {
        assert_eq!(
            (a.off, a.size, a.base, a.counter0),
            (b.off, b.size, b.base, b.counter0),
            "range"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

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

/// P1-6: manga images (`img_*`) must count toward the same `src_dir`
/// budget as videos and be evicted oldest-first; in-flight and
/// unrelated files must never be deleted.
#[test]
fn src_cache_prune_evicts_oldest_manga_images_too() {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-prune-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let write_at = |name: &str, size: usize, secs: u64| {
        let path = dir.join(name);
        std::fs::write(&path, vec![b'x'; size]).expect("write cache file");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .expect("open cache file")
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs))
            .expect("set mtime");
        path
    };
    let old_video = write_at("old.mp4", 60, 50);
    let old_image = write_at("img_old.png", 60, 100);
    let new_image = write_at("img_new.png", 60, 200);
    let in_flight = write_at("img_tmp.png.part", 60, 10);
    let unrelated = write_at("notes.txt", 60, 10);

    // Total counted = 180 (video + 2 images); budget 100 forces eviction
    // of the oldest first: old video, then old image. The kept (newest)
    // image, the in-flight part file, and the unrelated file survive.
    prune_src_cache_with_budget(&dir.to_string_lossy(), &new_image, 100);

    assert!(!old_video.exists(), "oldest video must be evicted");
    assert!(!old_image.exists(), "oldest manga image must be evicted");
    assert!(new_image.exists(), "kept image must survive");
    assert!(in_flight.exists(), "in-flight .part must never be deleted");
    assert!(unrelated.exists(), "unrelated files must never be deleted");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Eviction now runs off the request path, once at a time. While a pass
/// holds the lock a newly scheduled one must skip instead of queueing, and
/// once the lock is free the next request's pass evicts.
#[tokio::test]
async fn scheduled_prune_runs_in_the_background_and_never_overlaps() {
    let dir = std::env::temp_dir().join(format!(
        "fqapp-prune-bg-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let write_at = |name: &str, secs: u64| {
        let path = dir.join(name);
        std::fs::write(&path, vec![b'x'; 60]).expect("write cache file");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .expect("open cache file")
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs))
            .expect("set mtime");
        path
    };
    let old_video = write_at("old.mp4", 50);
    let new_video = write_at("new.mp4", 200);
    let src_dir = dir.to_string_lossy().into_owned();

    // Hold the pass lock: a scheduled pass must skip while one is
    // already running instead of queueing behind it.
    let guard = PRUNE_LOCK.lock().await;
    schedule_prune_src_cache_with_budget(&src_dir, new_video.clone(), 100);
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
    assert!(
        old_video.exists(),
        "a scheduled pass must not run while one is already running"
    );
    drop(guard);

    // Once the lock is free the next scheduled pass evicts. Retry because
    // other tests in this binary share the same pass lock.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while old_video.exists() && tokio::time::Instant::now() < deadline {
        schedule_prune_src_cache_with_budget(&src_dir, new_video.clone(), 100);
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(
        !old_video.exists(),
        "the scheduled pass must evict the oldest file"
    );
    assert!(new_video.exists(), "the kept file must survive");
    let _ = std::fs::remove_dir_all(&dir);
}

/// P1-9: the download must stream chunk by chunk (never hold the whole
/// file in memory) and enforce the per-file cap, both from an
/// advertised `Content-Length` and from the running byte count.
/// A local TCP server stands in for the upstream host.
async fn serve_once(body: Vec<u8>, advertised: Option<u64>) -> (u16, tokio::task::JoinHandle<()>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind test server");
    let port = listener.local_addr().expect("test server addr").port();
    let handle = tokio::spawn(async move {
        if let Ok((mut socket, _)) = listener.accept().await {
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await;
            let header = match advertised {
                Some(len) => {
                    format!("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {len}\r\n\r\n")
                }
                None => "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_string(),
            };
            let _ = socket.write_all(header.as_bytes()).await;
            let _ = socket.write_all(&body).await;
            let _ = socket.shutdown().await;
        }
    });
    (port, handle)
}

fn ensure_test_crypto_provider() {
    // The streaming client is built with rustls-no-provider, so it
    // needs the process-wide default provider the upstream transport
    // normally installs at startup. Mirror `upstream/http.rs`.
    let _ = rustls::crypto::ring::default_provider().install_default();
}

#[tokio::test]
async fn stream_download_writes_body_without_whole_file_buffer() {
    ensure_test_crypto_provider();
    let body: Vec<u8> = (0..10_000u32).map(|i| (i % 251) as u8).collect();
    let (port, server) = serve_once(body.clone(), Some(body.len() as u64)).await;
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let part = dir.join("ep.mp4.part");
    let url = format!("http://127.0.0.1:{port}/ep.mp4");
    let total = stream_download_to_file(&url, UA_WINDOWS_BROWSER, &part)
        .await
        .expect("stream download");
    assert_eq!(total, body.len() as u64);
    assert_eq!(std::fs::read(&part).expect("read part"), body);
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn stream_download_rejects_lying_content_length() {
    ensure_test_crypto_provider();
    let body = vec![b'x'; 64];
    let (port, server) = serve_once(body, Some(MAX_VIDEO_DOWNLOAD_BYTES + 1)).await;
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-cap-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let part = dir.join("ep.mp4.part");
    let url = format!("http://127.0.0.1:{port}/ep.mp4");
    let err = stream_download_to_file(&url, UA_WINDOWS_BROWSER, &part)
        .await
        .expect_err("lying Content-Length must be rejected");
    assert!(err.contains("content-length"), "unexpected error: {err}");
    assert!(
        !part.exists(),
        "no file must be created on precheck failure"
    );
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn stream_download_enforces_cap_from_running_total() {
    ensure_test_crypto_provider();
    // No advertised length: the running byte count must stop the
    // download. A small cap keeps the test fast.
    let body = vec![b'y'; 100];
    let (port, server) = serve_once(body, None).await;
    let dir = std::env::temp_dir().join(format!(
        "fqapp-stream-total-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::create_dir_all(&dir);
    let part = dir.join("ep.mp4.part");
    let url = format!("http://127.0.0.1:{port}/ep.mp4");
    // Exercise the same loop with a small cap via the test-only seam.
    let err = stream_download_to_file_with_cap(&url, UA_WINDOWS_BROWSER, &part, 10)
        .await
        .expect_err("stream past the cap must be rejected");
    assert!(err.contains("exceeds cap"), "unexpected error: {err}");
    let _ = server.await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn merge_variant_rows_keeps_the_fallback_only_top_tier() {
    // 实测形状（2026-10-12）：主列表到 720P 为止，fallback 列表多一个
    // 1080p。合并后 1080P 必须在列表里，且同档不重复。
    const SPADE: &str = "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==";
    let primary = json!({
        "video_1": { "main_url": "https://example.test/360.mp4", "vwidth": 360, "vheight": 640,
            "codec_type": "bytevc1", "spade_a": SPADE },
        "video_2": { "main_url": "https://example.test/720.mp4", "vwidth": 720, "vheight": 1280,
            "codec_type": "bytevc1", "spade_a": SPADE }
    });
    let fallback = json!({
        "video_1": { "main_url": "https://example.test/720.mp4", "vwidth": 720, "vheight": 1280,
            "codec_type": "bytevc1", "spade_a": SPADE },
        "video_2": { "main_url": "https://example.test/1080.mp4", "vwidth": 1080, "vheight": 1920,
            "codec_type": "bytevc1", "spade_a": SPADE }
    });
    let mut scored = variant_rows_scored(primary.as_object(), Some(b"AAAA".to_vec()));
    scored.extend(variant_rows_scored(
        fallback.as_object(),
        Some(b"AAAA".to_vec()),
    ));
    let rows = merge_variant_rows(scored);
    let names: Vec<&str> = rows.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(
        names,
        ["1080P", "720P", "360P"],
        "fallback-only tier must be merged in and duplicates collapsed"
    );
    for row in &rows {
        assert_eq!(row["key_hex"].as_str().unwrap().len(), 32);
    }
}

#[test]
fn merge_variant_rows_still_drops_bytevc2_from_the_fallback_list() {
    // fallback 列表里 1080p 常是 bytevc1、低档是 bytevc2（实测 4/6 部剧）。
    // 合并不得把 bytevc2 带进面板。
    const SPADE: &str = "orws8mOJLdlTlhnvZZQr32GULuhXkBvtUpAf7GWQKNtUohyPjw==";
    let fallback = json!({
        "video_1": { "main_url": "https://example.test/1080-vvc.mp4", "vwidth": 1080, "vheight": 1920,
            "codec_type": "bytevc2", "spade_a": SPADE },
        "video_2": { "main_url": "https://example.test/1080-hvc1.mp4", "vwidth": 1080, "vheight": 1920,
            "codec_type": "bytevc1", "spade_a": SPADE },
        "video_3": { "main_url": "https://example.test/720-vvc.mp4", "vwidth": 720, "vheight": 1280,
            "codec_type": "bytevc2", "spade_a": SPADE }
    });
    let rows = merge_variant_rows(variant_rows_scored(
        fallback.as_object(),
        Some(b"AAAA".to_vec()),
    ));
    let names: Vec<&str> = rows.iter().map(|v| v["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["1080P"], "bytevc2 rows must never reach the panel");
}
