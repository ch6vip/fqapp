//! a_bogus signature used by the fanqienovel.com web API.
//! Port of `/internal/sign/abogus.go`.

use rand::Rng;

const ABOGUS_TABLES: [(&str, &str); 5] = [
    (
        "s0",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=",
    ),
    (
        "s1",
        "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=",
    ),
    (
        "s2",
        "Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=",
    ),
    (
        "s3",
        "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe",
    ),
    (
        "s4",
        "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe=",
    ),
];

fn table(typ: &str) -> &'static str {
    for (name, dict) in ABOGUS_TABLES {
        if name == typ {
            return dict;
        }
    }
    ABOGUS_TABLES[0].1
}

const AB_INIT_REG: [u32; 8] = [
    1_937_774_191,
    1_226_093_241,
    388_252_375,
    0xDA8A_0600,
    0xA96F_30BC,
    372_324_522,
    0xE38D_EE4D,
    0xB0FB_0E4E,
];

fn rotl32(e: u32, r: u32) -> u32 {
    let r = r % 32;
    if r == 0 {
        e
    } else {
        e.rotate_left(r)
    }
}

fn ab_constant_tj(e: usize) -> u32 {
    if e < 16 {
        2_043_430_169
    } else {
        2_055_708_042
    }
}

fn ab_ff(e: usize, r: u32, t: u32, n: u32) -> u32 {
    if e < 16 {
        r ^ t ^ n
    } else {
        (r & t) | (r & n) | (t & n)
    }
}

fn ab_gg(e: usize, r: u32, t: u32, n: u32) -> u32 {
    if e < 16 {
        r ^ t ^ n
    } else {
        (r & t) | (!r & n)
    }
}

pub fn ab_sm3(data: &[u8]) -> [u8; 32] {
    let mut reg = AB_INIT_REG;

    let mut a: Vec<i64> = data.iter().map(|b| *b as i64).collect();
    let size = a.len() * 8;
    a.push(128);

    let mut f = a.len() % 64;
    if f > 56 {
        while f < 64 {
            a.push(0);
            f += 1;
        }
        f = 0;
    }
    while f < 56 {
        a.push(0);
        f += 1;
    }
    for i in (0..8).rev() {
        a.push(((size >> (i * 8)) & 255) as i64);
    }

    let mut offset = 0;
    while offset < a.len() {
        if offset + 64 <= a.len() {
            reg = ab_compress(reg, &a[offset..offset + 64]);
        }
        offset += 64;
    }

    let mut result = [0u8; 32];
    for i in 0..8 {
        let mut c = reg[i];
        result[i * 4 + 3] = (c & 255) as u8;
        c >>= 8;
        result[i * 4 + 2] = (c & 255) as u8;
        c >>= 8;
        result[i * 4 + 1] = (c & 255) as u8;
        c >>= 8;
        result[i * 4] = (c & 255) as u8;
    }
    result
}

fn ab_compress(mut reg: [u32; 8], block: &[i64]) -> [u32; 8] {
    let w = ab_prepare_message(block);
    let mut a = reg;

    for j in 0..64usize {
        let ss1 = rotl32(
            rotl32(a[0], 12)
                .wrapping_add(a[4])
                .wrapping_add(rotl32(ab_constant_tj(j), j as u32)),
            7,
        );
        let ss2 = ss1 ^ rotl32(a[0], 12);
        let tt1 = ab_ff(j, a[0], a[1], a[2])
            .wrapping_add(a[3])
            .wrapping_add(ss2)
            .wrapping_add(w[j + 68]);
        let tt2 = ab_gg(j, a[4], a[5], a[6])
            .wrapping_add(a[7])
            .wrapping_add(ss1)
            .wrapping_add(w[j]);

        a[3] = a[2];
        a[2] = rotl32(a[1], 9);
        a[1] = a[0];
        a[0] = tt1;
        a[7] = a[6];
        a[6] = rotl32(a[5], 19);
        a[5] = a[4];
        a[4] = tt2 ^ rotl32(tt2, 9) ^ rotl32(tt2, 17);
    }

    for i in 0..8 {
        reg[i] ^= a[i];
    }
    reg
}

fn ab_prepare_message(block: &[i64]) -> [u32; 132] {
    let mut w = [0u32; 132];
    for i in 0..16 {
        w[i] = ((block[i * 4] as u32) << 24)
            | ((block[i * 4 + 1] as u32) << 16)
            | ((block[i * 4 + 2] as u32) << 8)
            | (block[i * 4 + 3] as u32);
    }
    for i in 16..68 {
        let mut temp = w[i - 16] ^ w[i - 9] ^ rotl32(w[i - 3], 15);
        temp = temp ^ rotl32(temp, 15) ^ rotl32(temp, 23);
        w[i] = temp ^ rotl32(w[i - 13], 7) ^ w[i - 6];
    }
    for i in 0..64 {
        w[i + 68] = w[i] ^ w[i + 4];
    }
    w
}

pub fn rc4(plaintext: &[u8], key: &[u8]) -> Vec<u8> {
    let mut s: [i32; 256] = [0; 256];
    for (i, slot) in s.iter_mut().enumerate() {
        *slot = i as i32;
    }
    let mut j = 0usize;
    for i in 0..256 {
        j = (j + s[i] as usize + key[i % key.len()] as usize) % 256;
        s.swap(i, j);
    }

    let mut out = vec![0u8; plaintext.len()];
    let (mut i, mut j) = (0usize, 0usize);
    for k in 0..plaintext.len() {
        i = (i + 1) % 256;
        j = (j + s[i] as usize) % 256;
        s.swap(i, j);
        let t = (s[i] + s[j]) % 256;
        out[k] = plaintext[k] ^ (s[t as usize] as u8);
    }
    out
}

pub fn ab_result_encrypt(data: &[u8], typ: &str) -> String {
    let dict = table(typ).as_bytes();

    let mut result: Vec<u8> = Vec::new();
    let length = data.len();
    let mut i = 0;
    while i < length {
        let b0 = data[i] as i32;
        let b1 = if i + 1 < length {
            data[i + 1] as i32
        } else {
            0
        };
        let b2 = if i + 2 < length {
            data[i + 2] as i32
        } else {
            0
        };
        let combined = (b0 << 16) | (b1 << 8) | b2;
        for jj in 0..4i32 {
            if (i as i32) * 8 + jj * 6 <= (length as i32) * 8 {
                let index = ((combined >> (18 - jj * 6)) & 63) as usize;
                if index < dict.len() {
                    result.push(dict[index]);
                }
            } else if dict.len() > 64 {
                result.push(dict[64]);
            }
        }
        i += 3;
    }
    String::from_utf8_lossy(&result).into_owned()
}

fn ab_generate_random(random: i32, option: [i32; 2]) -> [i32; 4] {
    [
        (random & 255 & 170) | (option[0] & 85),
        (random & 255 & 85) | (option[0] & 170),
        ((random >> 8) & 255 & 170) | (option[1] & 85),
        ((random >> 8) & 255 & 85) | (option[1] & 170),
    ]
}

pub fn ab_generate_random_str<R: Rng>(rng: &mut R) -> Vec<u8> {
    let mut out = Vec::new();
    let opts_list: [[i32; 2]; 3] = [[3, 45], [1, 0], [1, 5]];
    for opt in opts_list {
        let random = rng.gen_range(0..65536i32);
        for b in ab_generate_random(random, opt) {
            out.push(b as u8);
        }
    }
    out
}

pub fn ab_generate_rc4_bb_str(
    url_search_params: &str,
    user_agent: &str,
    window_env_str: &str,
    suffix: &str,
    arguments: [i32; 3],
    start_time: i64,
    end_time: i64,
) -> Vec<u8> {
    let url_hash = ab_sm3(&ab_sm3(format!("{url_search_params}{suffix}").as_bytes()));
    let cus_hash = ab_sm3(&ab_sm3(suffix.as_bytes()));

    let ua_encrypted = rc4(user_agent.as_bytes(), &[1, b' ', 14]);
    let ua_hash = ab_sm3(ab_result_encrypt(&ua_encrypted, "s3").as_bytes());

    let mut d = [0i64; 73];
    d[8] = 3;
    d[10] = end_time;
    d[16] = start_time;
    d[18] = 44;

    d[20] = (start_time >> 24) & 255;
    d[21] = (start_time >> 16) & 255;
    d[22] = (start_time >> 8) & 255;
    d[23] = start_time & 255;
    d[24] = start_time / 0x1_0000_0000;
    d[25] = start_time / 0x100_0000_0000;

    let a0 = arguments[0] as i64;
    let a1 = arguments[1] as i64;
    let a2 = arguments[2] as i64;
    d[26] = (a0 >> 24) & 255;
    d[27] = (a0 >> 16) & 255;
    d[28] = (a0 >> 8) & 255;
    d[29] = a0 & 255;
    d[30] = (a1 / 256) & 255;
    d[31] = (a1 % 256) & 255;
    d[32] = (a1 >> 24) & 255;
    d[33] = (a1 >> 16) & 255;
    d[34] = (a2 >> 24) & 255;
    d[35] = (a2 >> 16) & 255;
    d[36] = (a2 >> 8) & 255;
    d[37] = a2 & 255;

    d[38] = url_hash[21] as i64;
    d[39] = url_hash[22] as i64;
    d[40] = cus_hash[21] as i64;
    d[41] = cus_hash[22] as i64;
    d[42] = ua_hash[23] as i64;
    d[43] = ua_hash[24] as i64;

    d[44] = (end_time >> 24) & 255;
    d[45] = (end_time >> 16) & 255;
    d[46] = (end_time >> 8) & 255;
    d[47] = end_time & 255;
    d[48] = d[8];
    d[49] = end_time / 0x1_0000_0000;
    d[50] = end_time / 0x100_0000_0000;

    d[51] = 6241;
    d[52] = (d[51] >> 24) & 255;
    d[53] = (d[51] >> 16) & 255;
    d[54] = (d[51] >> 8) & 255;
    d[55] = d[51] & 255;
    d[56] = 6383;
    d[57] = d[56] & 255;
    d[58] = (d[56] >> 8) & 255;
    d[59] = (d[56] >> 16) & 255;
    d[60] = (d[56] >> 24) & 255;

    let window_env_list = window_env_str.as_bytes();
    d[64] = window_env_list.len() as i64;
    d[65] = d[64] & 255;
    d[66] = (d[64] >> 8) & 255;
    d[69] = 0;
    d[70] = d[69] & 255;
    d[71] = (d[69] >> 8) & 255;

    d[72] = d[18]
        ^ d[20]
        ^ d[26]
        ^ d[30]
        ^ d[38]
        ^ d[40]
        ^ d[42]
        ^ d[21]
        ^ d[27]
        ^ d[31]
        ^ d[35]
        ^ d[39]
        ^ d[41]
        ^ d[43]
        ^ d[22]
        ^ d[28]
        ^ d[32]
        ^ d[36]
        ^ d[23]
        ^ d[29]
        ^ d[33]
        ^ d[37]
        ^ d[44]
        ^ d[45]
        ^ d[46]
        ^ d[47]
        ^ d[48]
        ^ d[49]
        ^ d[50]
        ^ d[24]
        ^ d[25]
        ^ d[52]
        ^ d[53]
        ^ d[54]
        ^ d[55]
        ^ d[57]
        ^ d[58]
        ^ d[59]
        ^ d[60]
        ^ d[65]
        ^ d[66]
        ^ d[70]
        ^ d[71];

    let order = [
        18usize, 20, 52, 26, 30, 34, 58, 38, 40, 53, 42, 21, 27, 54, 55, 31, 35, 57, 39, 41, 43,
        22, 28, 32, 60, 36, 23, 29, 33, 37, 44, 45, 59, 46, 47, 48, 49, 50, 24, 25, 65, 66, 70, 71,
    ];
    let mut bb: Vec<u8> = Vec::new();
    for k in order {
        bb.push(d[k] as u8);
    }
    bb.extend_from_slice(window_env_list);
    bb.push(d[72] as u8);

    rc4(&bb, b"y")
}

/// Builds the a_bogus signature (non-deterministic: embeds live timestamps and
/// RNG bytes).
pub fn generate_a_bogus(url_search_params: &str, user_agent: &str) -> String {
    let mut rng = rand::thread_rng();
    let random_part = ab_generate_random_str(&mut rng);
    let start = crate::timeutil::now_millis();
    let end = crate::timeutil::now_millis();
    let encrypted_part = ab_generate_rc4_bb_str(
        url_search_params,
        user_agent,
        "1536|747|1536|834|0|30|0|0|1536|834|1536|864|1525|747|24|24|Win32",
        "cus",
        [0, 1, 14],
        start,
        end,
    );

    let mut result = random_part;
    result.extend_from_slice(&encrypted_part);
    format!("{}=", ab_result_encrypt(&result, "s4"))
}
