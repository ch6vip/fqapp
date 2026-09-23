//! x-argus: ordered protobuf bean -> PKCS7 -> Simon -> framing -> AES-CBC.
//! Port of `/internal/sign/argus.go`.

use std::sync::OnceLock;

use base64::Engine as _;
use rand::Rng;

use crate::crypto::aes_cbc_encrypt;
use crate::sign::protobuf::ProtoBuf;
use crate::sign::simon::simon_enc;
use crate::sign::sm3::sm3_hash;

const ARGUS_SIGN_KEY_HEX: &str = "fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304";
const ARGUS_AES_KEY_HEX: &str = "d31e3718288a1027baab59f146a09a9c";
const ARGUS_AES_IV_HEX: &str = "ea180a0336ed352fcd24e4d50018ae54";

fn sign_key() -> &'static [u8] {
    static K: OnceLock<Vec<u8>> = OnceLock::new();
    K.get_or_init(|| hex::decode(ARGUS_SIGN_KEY_HEX).expect("argus sign key"))
}

fn aes_key() -> &'static [u8] {
    static K: OnceLock<Vec<u8>> = OnceLock::new();
    K.get_or_init(|| hex::decode(ARGUS_AES_KEY_HEX).expect("argus aes key"))
}

fn aes_iv() -> &'static [u8] {
    static K: OnceLock<Vec<u8>> = OnceLock::new();
    K.get_or_init(|| hex::decode(ARGUS_AES_IV_HEX).expect("argus aes iv"))
}

fn sm3_prefix6(msg: &[u8]) -> [u8; 6] {
    let h = sm3_hash(msg);
    let mut out = [0u8; 6];
    out.copy_from_slice(&h[..6]);
    out
}

/// `getBodyHash(stub)`.
pub fn argus_body_hash(stub_hex: &str) -> [u8; 6] {
    if stub_hex.is_empty() {
        return sm3_prefix6(&[0u8; 16]);
    }
    let raw = hex::decode(stub_hex).unwrap_or_default();
    sm3_prefix6(&raw)
}

/// `getQueryHash(query)`.
pub fn argus_query_hash(query: &str) -> [u8; 6] {
    if query.is_empty() {
        return sm3_prefix6(&[0u8; 16]);
    }
    sm3_prefix6(query.as_bytes())
}

/// `encryptEncPb($data, $length)` with `length = len(data) + 8`.
pub fn argus_encrypt_enc_pb(data: &[u8], length: usize) -> Vec<u8> {
    let mut buf = vec![0u8; length];
    let n = data.len().min(length);
    buf[..n].copy_from_slice(&data[..n]);
    let xor_key = &data[..8];
    for i in 8..length {
        let src = if i < data.len() { data[i] } else { 0 };
        buf[i] = src ^ xor_key[i % 8];
    }
    buf.reverse();
    buf
}

fn simon_key_list() -> [u64; 4] {
    let key = sign_key();
    let mut out = [0u64; 4];
    for i in 0..4 {
        let mut b = [0u8; 8];
        b.copy_from_slice(&key[i * 8..i * 8 + 8]);
        out[i] = u64::from_le_bytes(b);
    }
    out
}

fn simon_encrypt_padded(protobuf: &[u8]) -> Vec<u8> {
    let key = simon_key_list();
    let mut enc_pb = vec![0u8; protobuf.len()];
    for i in 0..protobuf.len() / 16 {
        let block = &protobuf[i * 16..i * 16 + 16];
        let mut a = [0u8; 8];
        let mut b = [0u8; 8];
        a.copy_from_slice(&block[..8]);
        b.copy_from_slice(&block[8..]);
        let ct = simon_enc([u64::from_le_bytes(a), u64::from_le_bytes(b)], key);
        enc_pb[i * 16..i * 16 + 8].copy_from_slice(&ct[0].to_le_bytes());
        enc_pb[i * 16 + 8..i * 16 + 16].copy_from_slice(&ct[1].to_le_bytes());
    }
    enc_pb
}

fn pkcs7_align(data: &mut Vec<u8>) {
    let pad_len = 16 - (data.len() % 16);
    data.extend(std::iter::repeat_n(pad_len as u8, pad_len));
}

/// Legacy (PHP 55 / SignatureManager) encryption path.
pub fn argus_encrypt(bean: &ProtoBuf) -> String {
    let mut protobuf = bean.to_buf();
    pkcs7_align(&mut protobuf);
    let new_len = protobuf.len();

    let enc_pb = simon_encrypt_padded(&protobuf);
    let mut b_buffer = argus_encrypt_enc_pb(&enc_pb, new_len + 8);
    b_buffer.push(b'a');
    b_buffer.push(b'o');

    pkcs7_align(&mut b_buffer);
    let out = aes_cbc_encrypt(&b_buffer, aes_key(), aes_iv());
    base64::engine::general_purpose::STANDARD.encode(out)
}

const ARGUS_551_PREFIX: [u8; 2] = [0xf2, 0x81];
const ARGUS_551_MAGIC8: [u8; 8] = [0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff];
const ARGUS_551_TAIL9: [u8; 9] = [0xea, 0xfb, 0x2c, 0xfe, 0x85, 0x68, 0x51, 0x91, 0x54];

/// The x-argus wrapper accepted by the real fanqie upstream.
pub fn argus_encrypt_551(bean: &ProtoBuf) -> String {
    let mut protobuf = bean.to_buf();
    pkcs7_align(&mut protobuf);

    let enc_pb = simon_encrypt_padded(&protobuf);

    let mut un = Vec::with_capacity(8 + enc_pb.len() + 9);
    un.extend_from_slice(&ARGUS_551_MAGIC8);
    un.extend_from_slice(&enc_pb);
    un.extend_from_slice(&ARGUS_551_TAIL9);

    let mut buf = vec![0u8; un.len()];
    buf[..8].copy_from_slice(&ARGUS_551_MAGIC8);
    for i in 8..un.len() {
        buf[i] = un[i] ^ ARGUS_551_MAGIC8[i % 8];
    }
    buf.reverse();
    buf.push(b'a');
    buf.push(b'o');

    pkcs7_align(&mut buf);
    let out = aes_cbc_encrypt(&buf, aes_key(), aes_iv());

    let mut raw = ARGUS_551_PREFIX.to_vec();
    raw.extend_from_slice(&out);
    base64::engine::general_purpose::STANDARD.encode(raw)
}

/// Bean layout selector for x-argus.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArgusBeanStyle {
    /// Legacy bean layout.
    ArgusBeanPhp55,
    /// SignatureManager layout.
    ArgusBeanSigMgr,
    /// Current layout: fields 8-11 plus the 551 framing.
    ArgusBean551,
}

/// Runtime inputs for building the x-argus bean.
#[derive(Debug, Clone)]
pub struct ArgusParams {
    pub query_string: String,
    pub stub_hex: String,
    pub timestamp: i64,
    pub aid: i64,
    pub license_id: i64,
    pub device_id: String,
    /// Written to bean field 16 when non-empty.
    pub install_id: String,
    pub style: ArgusBeanStyle,
    pub rand_field: i32,
}

pub fn argus_get_sign(p: &ArgusParams) -> String {
    let aid = if p.aid == 0 { 1967 } else { p.aid };
    let license_id = if p.license_id == 0 {
        1_611_921_764
    } else {
        p.license_id
    };
    let rand_field = if p.rand_field == 0 {
        rand::thread_rng().gen::<i32>()
    } else {
        p.rand_field
    };

    let mut bean = ProtoBuf::new();
    bean.put_varint(1, 1_077_940_818);
    bean.put_varint(2, 2);
    bean.put_varint(3, rand_field as i64);
    bean.put_utf8(4, &aid.to_string());
    bean.put_utf8(5, &p.device_id);
    bean.put_utf8(6, &license_id.to_string());
    bean.put_utf8(
        7,
        &crate::sign::query_param(&p.query_string, "version_name").unwrap_or_default(),
    );
    match p.style {
        ArgusBeanStyle::ArgusBean551 => {
            bean.put_utf8(8, "v04.04.05-ov-android");
            bean.put_varint(9, 134_744_640);
            bean.put_bytes(10, &[0u8; 8]);
            bean.put_varint(11, 0);
        }
        ArgusBeanStyle::ArgusBeanSigMgr => {
            bean.put_utf8(8, "v04.04.05-ov-android");
            bean.put_varint(9, 134_744_640);
            bean.put_utf8(10, "");
            bean.put_utf8(11, "0");
        }
        ArgusBeanStyle::ArgusBeanPhp55 => {
            bean.put_utf8(8, "");
            bean.put_varint(9, 0);
            bean.put_utf8(10, "");
            bean.put_utf8(11, "");
        }
    }
    bean.put_varint(12, p.timestamp << 1);
    bean.put_bytes(13, &argus_body_hash(&p.stub_hex));
    bean.put_bytes(14, &argus_query_hash(&p.query_string));

    let mut sub15 = ProtoBuf::new();
    sub15.put_varint(1, 1);
    sub15.put_varint(2, 1);
    sub15.put_varint(3, 1);
    sub15.put_varint(7, 0xC792_ECCC);
    bean.put_protobuf(15, &sub15);

    bean.put_utf8(16, &p.install_id);
    bean.put_utf8(20, "none");
    bean.put_varint(21, 738);

    let mut sub23 = ProtoBuf::new();
    sub23.put_utf8(1, "NX551J");
    sub23.put_varint(2, 8196);
    sub23.put_varint(4, 0x80E0_D800);
    bean.put_protobuf(23, &sub23);

    bean.put_varint(25, 2);

    if p.style == ArgusBeanStyle::ArgusBean551 {
        argus_encrypt_551(&bean)
    } else {
        argus_encrypt(&bean)
    }
}
