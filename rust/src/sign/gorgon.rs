//! x-gorgon 8404 scheme. Legacy/dead for the current upstream but still
//! requested while a device registers. Port of `/internal/sign/gorgon.go`.

use md5::{Digest, Md5};
use rand::Rng;

// The `(x | x)` / `(x & x)` pair below is a literal port of the reference implementation
// implementation (/internal/sign/gorgon.go). It is dead arithmetic that the
// upstream scheme carries, and changing it would change the emitted bytes, so
// the lint is silenced deliberately rather than "fixed".
#[allow(clippy::eq_op)]
pub fn generate_x_gorgon(param: &str) -> String {
    let ts = crate::timeutil::now_secs();
    let time_bytes = (ts as u32).to_be_bytes();

    let mut hasher = Md5::new();
    hasher.update(param.as_bytes());
    let sum = hasher.finalize();
    let md5_prefix = &sum[..4];

    let mut data: Vec<u8> = Vec::with_capacity(16);
    data.extend_from_slice(md5_prefix);
    data.extend_from_slice(&[0, 0, 0, 0, 0, 1, 7, 4]);
    data.extend_from_slice(&time_bytes);

    let mut table: Vec<i64> = (0..256i64).collect();

    let rnd: [u8; 2] = rand::thread_rng().gen();
    let r1 = rnd[0] as i64;
    let r2 = rnd[1] as i64;
    let key = [74i64, 0, 22, r2, 71, 108, 0, r1];

    let mut j: i64 = 0;
    for i in 0..256usize {
        j = (j + table[i] + key[i & 7]) & 0xFFFF_FFFF;
        j &= 255;
        table[i] = table[j as usize];
    }

    let dlen = data.len();
    let mut k: i64 = 0;
    for i in 1..=dlen {
        let idx = ((((i as i64 - 1) ^ 1) + ((i as i64 - 1) & 1)) << 1) & 255;
        let idx = idx as usize;

        let table_val = table[idx];
        let xor_val = k ^ table_val;
        k = (((k | table_val) << 1) - xor_val) & 0xFFFF_FFFF;

        let idx2 = (k & 255) as usize;
        let table_val2 = table[idx2];
        table[idx] = table_val2;
        table[idx2] = table_val2;

        let enc_idx = ((table_val2 | table_val2) + (table_val2 & table_val2)) & 255;
        data[i - 1] = ((data[i - 1] as i64) ^ table[enc_idx as usize]) as u8;
    }

    const W2: i64 = 0xFFFF_FFAA;
    const W3: i64 = 85;
    const W4: i64 = 51;
    let len_inv = (!(dlen as i64)) & 0xFFFF_FFFF;

    for i in 1..=dlen {
        let mut val = data[i - 1] as i64;

        val = ((val >> 4) & 15) | ((val & 15) << 4);
        data[i - 1] = (val & 255) as u8;

        if i == dlen {
            data[i - 1] = (val ^ (data[0] as i64)) as u8;
        } else {
            let next = data[i] as i64;
            data[i - 1] = ((val | next) - (val & next)) as u8;
        }

        let mut val = data[i - 1] as i64;

        let t1 = W2 & (val << 1);
        let t2 = W3 & (val >> 1);
        val = t1 | t2;

        let t3 = val << 2;
        let t4 = W4 & (val >> 2);
        let mut mix = (t3 & 0xFFFF_FFCF) | t4;

        let high = (mix >> 4) & 15;
        let low = mix & 268_435_455;
        mix = (low << 4) | high;

        val = mix ^ len_inv;
        data[i - 1] = (val & 255) as u8;
    }

    let mut out: Vec<u8> = Vec::with_capacity(6 + data.len());
    out.extend_from_slice(&[132, 4, rnd[0], rnd[1], 0, 0]);
    out.extend_from_slice(&data);
    hex::encode(out)
}
