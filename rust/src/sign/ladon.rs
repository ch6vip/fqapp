//! x-ladon: a custom 34-round ARX block cipher over u64.

use base64::Engine as _;
use md5::{Digest, Md5};

/// Builds the 288-byte hash table from the 32-char lowercase md5 hex string.
pub fn ladon_expand_hash_table(md5_hex: &str) -> [u8; 288] {
    let mut ht = [0u8; 288];
    let bytes = md5_hex.as_bytes();
    let prefix_len = 32.min(bytes.len());
    ht[..prefix_len].copy_from_slice(&bytes[..prefix_len]);

    let load = |ht: &[u8; 288], off: usize| -> u64 {
        let mut v = 0u64;
        for j in 0..8 {
            v |= (ht[off + j] as u64) << (j * 8);
        }
        v
    };

    let mut temp: Vec<u64> = (0..4).map(|i| load(&ht, i * 8)).collect();
    let mut buf_b0 = temp[0];
    let mut buf_b8 = temp[1];
    temp.drain(0..2);

    for i in 0..34usize {
        let x9 = buf_b0;
        let mut x8 = buf_b8;

        x8 = x8.rotate_right(8);
        x8 = x8.wrapping_add(x9);
        x8 ^= i as u64;
        temp.push(x8);

        let ror_x9 = x9.rotate_left(3);
        x8 ^= ror_x9;

        for j in 0..8 {
            ht[(i + 1) * 8 + j] = ((x8 >> (j * 8)) & 255) as u8;
        }

        buf_b0 = x8;
        buf_b8 = temp[0];
        temp.remove(0);
    }
    ht
}

pub fn ladon_encrypt_block(ht: &[u8; 288], block: &[u8]) -> [u8; 16] {
    let mut data0 = 0u64;
    let mut data1 = 0u64;
    for i in 0..8 {
        data0 |= (block[i] as u64) << (i * 8);
        data1 |= (block[8 + i] as u64) << (i * 8);
    }

    for i in 0..34usize {
        let mut hash = 0u64;
        for j in 0..8 {
            hash |= (ht[i * 8 + j] as u64) << (j * 8);
        }
        let rotated = data1.rotate_right(8);
        let sum = data0.wrapping_add(rotated);
        data1 = hash ^ sum;

        let rotated = data0.rotate_left(3);
        data0 = data1 ^ rotated;
    }

    let mut out = [0u8; 16];
    for i in 0..8 {
        out[i] = ((data0 >> (i * 8)) & 255) as u8;
        out[8 + i] = ((data1 >> (i * 8)) & 255) as u8;
    }
    out
}

pub fn ladon_encrypt_raw(md5_hex: &str, data: &[u8]) -> Vec<u8> {
    let ht = ladon_expand_hash_table(md5_hex);

    let size = data.len();
    let new_size = size + (16 - size % 16);
    let pad_val = (new_size - size) as u8;
    let mut input = vec![pad_val; new_size];
    input[..size].copy_from_slice(data);

    let mut out = Vec::with_capacity(new_size);
    for i in 0..new_size / 16 {
        out.extend_from_slice(&ladon_encrypt_block(&ht, &input[i * 16..i * 16 + 16]));
    }
    out
}

/// x-ladon value from khronos, lcId, aid and 4 random bytes.
pub fn ladon_encrypt(khronos: i64, lc_id: i64, aid: i64, random_bytes: &[u8]) -> String {
    let data = format!("{khronos}-{lc_id}-{aid}");

    let mut keygen = random_bytes.to_vec();
    keygen.extend_from_slice(aid.to_string().as_bytes());
    let mut hasher = Md5::new();
    hasher.update(&keygen);
    let md5_hex = hex::encode(hasher.finalize());

    let encrypted = ladon_encrypt_raw(&md5_hex, data.as_bytes());
    let mut out = random_bytes.to_vec();
    out.extend_from_slice(&encrypted);
    base64::engine::general_purpose::STANDARD.encode(out)
}
