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

mod cache;
mod decrypt;
mod download;
mod variants;
