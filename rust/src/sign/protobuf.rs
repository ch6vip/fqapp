//! Encode-only protobuf writer used by x-argus.
//! Port of `/internal/sign/protobuf.go`.
//!
//! `writeVarint` masks to 32 bits first, exactly like the Go original.

#[derive(Debug, Clone, Copy)]
struct ProtoField {
    idx: i32,
    typ: u8,
    v_uint: u64,
    v_bytes: usize,
}

#[derive(Debug, Default, Clone)]
pub struct ProtoBuf {
    fields: Vec<ProtoField>,
    blobs: Vec<Vec<u8>>,
}

impl ProtoBuf {
    pub fn new() -> Self {
        ProtoBuf::default()
    }

    pub fn put_varint(&mut self, idx: i32, v: i64) {
        self.fields.push(ProtoField {
            idx,
            typ: 0,
            v_uint: v as u64,
            v_bytes: 0,
        });
    }

    fn put_blob(&mut self, idx: i32, data: Vec<u8>) {
        self.blobs.push(data);
        self.fields.push(ProtoField {
            idx,
            typ: 2,
            v_uint: 0,
            v_bytes: self.blobs.len() - 1,
        });
    }

    pub fn put_utf8(&mut self, idx: i32, s: &str) {
        self.put_blob(idx, s.as_bytes().to_vec());
    }

    pub fn put_bytes(&mut self, idx: i32, data: &[u8]) {
        self.put_blob(idx, data.to_vec());
    }

    pub fn put_protobuf(&mut self, idx: i32, nested: &ProtoBuf) {
        let buf = nested.to_buf();
        self.put_blob(idx, buf);
    }

    pub fn to_buf(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for f in &self.fields {
            let key = ((f.idx as u64) << 3) | ((f.typ & 7) as u64);
            write_varint(&mut out, key);
            match f.typ {
                5 => out.extend_from_slice(&(f.v_uint as u32).to_le_bytes()),
                1 => out.extend_from_slice(&f.v_uint.to_le_bytes()),
                0 => write_varint(&mut out, f.v_uint),
                2 => {
                    let blob = &self.blobs[f.v_bytes];
                    write_varint(&mut out, blob.len() as u64);
                    out.extend_from_slice(blob);
                }
                _ => {}
            }
        }
        out
    }
}

fn write_varint(dst: &mut Vec<u8>, v: u64) {
    let mut v = v & 0xFFFF_FFFF;
    while v >= 128 {
        dst.push(((v & 127) | 128) as u8);
        v >>= 7;
    }
    dst.push((v & 127) as u8);
}
