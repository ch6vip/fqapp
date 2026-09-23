//! SM3, port of `/internal/sign/sm3.go`.

const SM3_IV: [u32; 8] = [
    0x7380_166f,
    0x4914_b2b9,
    0x1724_42d7,
    0xda8a_0600,
    0xa96f_30bc,
    0x1631_38aa,
    0xe38d_ee4d,
    0xb0fb_0e4e,
];

fn sm3_tj(j: usize) -> u32 {
    if j < 16 {
        0x79cc_4519
    } else {
        0x7a87_9d8a
    }
}

fn sm3_rotl(a: u32, k: usize) -> u32 {
    let k = (k % 32) as u32;
    if k == 0 {
        a
    } else {
        a.rotate_left(k)
    }
}

fn sm3_ff(x: u32, y: u32, z: u32, j: usize) -> u32 {
    if j < 16 {
        x ^ y ^ z
    } else {
        (x & y) | (x & z) | (y & z)
    }
}

fn sm3_gg(x: u32, y: u32, z: u32, j: usize) -> u32 {
    if j < 16 {
        x ^ y ^ z
    } else {
        (x & y) | (!x & z)
    }
}

fn sm3_p0(x: u32) -> u32 {
    x ^ sm3_rotl(x, 9) ^ sm3_rotl(x, 17)
}

fn sm3_p1(x: u32) -> u32 {
    x ^ sm3_rotl(x, 15) ^ sm3_rotl(x, 23)
}

fn sm3_cf(v: &[u32; 8], block: &[u8]) -> [u32; 8] {
    let mut w = [0u32; 68];
    for i in 0..16 {
        w[i] = u32::from_be_bytes([
            block[i * 4],
            block[i * 4 + 1],
            block[i * 4 + 2],
            block[i * 4 + 3],
        ]);
    }
    for j in 16..68 {
        w[j] = sm3_p1(w[j - 16] ^ w[j - 9] ^ sm3_rotl(w[j - 3], 15))
            ^ sm3_rotl(w[j - 13], 7)
            ^ w[j - 6];
    }
    let mut w1 = [0u32; 64];
    for j in 0..64 {
        w1[j] = w[j] ^ w[j + 4];
    }

    let (mut a, mut b, mut c, mut d) = (v[0], v[1], v[2], v[3]);
    let (mut e, mut f, mut g, mut h) = (v[4], v[5], v[6], v[7]);

    for j in 0..64 {
        let ss1 = sm3_rotl(
            sm3_rotl(a, 12)
                .wrapping_add(e)
                .wrapping_add(sm3_rotl(sm3_tj(j), j)),
            7,
        );
        let ss2 = ss1 ^ sm3_rotl(a, 12);
        let tt1 = sm3_ff(a, b, c, j)
            .wrapping_add(d)
            .wrapping_add(ss2)
            .wrapping_add(w1[j]);
        let tt2 = sm3_gg(e, f, g, j)
            .wrapping_add(h)
            .wrapping_add(ss1)
            .wrapping_add(w[j]);
        d = c;
        c = sm3_rotl(b, 9);
        b = a;
        a = tt1;
        h = g;
        g = sm3_rotl(f, 19);
        f = e;
        e = sm3_p0(tt2);
    }

    [
        a ^ v[0],
        b ^ v[1],
        c ^ v[2],
        d ^ v[3],
        e ^ v[4],
        f ^ v[5],
        g ^ v[6],
        h ^ v[7],
    ]
}

/// 32-byte SM3 digest, matching the Go padding exactly.
pub fn sm3_hash(msg: &[u8]) -> [u8; 32] {
    let orig_len = msg.len();
    let mut padded = Vec::with_capacity(orig_len + 72);
    padded.extend_from_slice(msg);
    padded.push(0x80);

    let reserve = (orig_len % 64) + 1;
    let mut range_end = 56usize;
    if range_end < reserve {
        range_end += 64;
    }
    padded.extend(std::iter::repeat_n(0u8, range_end - reserve));
    padded.extend_from_slice(&((orig_len as u64) * 8).to_be_bytes());

    let mut v = SM3_IV;
    for i in 0..padded.len() / 64 {
        v = sm3_cf(&v, &padded[i * 64..i * 64 + 64]);
    }

    let mut out = [0u8; 32];
    for i in 0..8 {
        out[i * 4..i * 4 + 4].copy_from_slice(&v[i].to_be_bytes());
    }
    out
}
