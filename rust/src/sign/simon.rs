//! Simon block cipher (128-bit key, 64-bit block, 72 rounds) used by x-argus.

const SIMON_Z: u64 = 0x3DC9_4C3A_046D_678B;

#[inline]
fn rotl(v: u64, n: u32) -> u64 {
    v.rotate_left(n)
}

#[inline]
fn rotr(v: u64, n: u32) -> u64 {
    v.rotate_right(n)
}

/// Key already holds the first 4 words.
pub fn simon_key_expansion(key: &mut [u64; 72]) {
    for i in 4..72 {
        let mut tmp = rotr(key[i - 1], 3);
        tmp ^= key[i - 3];
        tmp ^= rotr(tmp, 1);
        let not_val = !key[i - 4];
        let bit_val = (SIMON_Z >> ((i - 4) % 62)) & 1;
        key[i] = not_val ^ tmp ^ bit_val ^ 3;
    }
}

/// Encrypts one 128-bit block. Standard mode only (the only mode Argus uses).
pub fn simon_enc(pt: [u64; 2], k: [u64; 4]) -> [u64; 2] {
    let mut key = [0u64; 72];
    key[0] = k[0];
    key[1] = k[1];
    key[2] = k[2];
    key[3] = k[3];
    simon_key_expansion(&mut key);

    let mut xi = pt[0];
    let mut xi1 = pt[1];
    for &round_key in key.iter() {
        let tmp = xi1;
        let f = rotl(xi1, 1) & rotl(xi1, 8);
        xi1 = xi ^ f ^ rotl(xi1, 2) ^ round_key;
        xi = tmp;
    }
    [xi, xi1]
}

/// Inverse of `simon_enc`; used by offline diff/verify tooling.
pub fn simon_dec(ct: [u64; 2], k: [u64; 4]) -> [u64; 2] {
    let mut key = [0u64; 72];
    key[0] = k[0];
    key[1] = k[1];
    key[2] = k[2];
    key[3] = k[3];
    simon_key_expansion(&mut key);

    let mut x_left = ct[0];
    let mut x_right = ct[1];
    for i in (0..72).rev() {
        let tmp = x_left;
        let f = rotl(x_left, 1) & rotl(x_left, 8);
        x_left = x_right ^ f ^ rotl(x_left, 2) ^ key[i];
        x_right = tmp;
    }
    [x_left, x_right]
}
