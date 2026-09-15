// 独立验证：用后端下发的 spade_a 派生密钥，按 CENC-AES-CTR 解密真实加密音频流。
//
//   1. 读 /audio/play 响应，取 spade_a 与 main_url
//   2. 复刻 Go 端 deriveSpadeContentKey，得到 16 字节内容密钥
//   3. 解析 MP4 的 tenc / senc / stsz / stsc / stco，拿到逐样本 IV 与偏移
//   4. 计数器块 = per_sample_iv(8) || 0^8，AES-128-CTR 解密每个样本
//   5. raw AAC 帧的前 3 bit 是元素类型（SCE=000 / CPE=001）——随机数据满足
//      该条件的概率是 (1/4)^N，所以"全部样本都像 AAC 帧头"是对密钥正确性的强验证
//
// 用法: node scripts/verify_audio_cenc.cjs <play-response.json>
//
// play-response.json 是 GET /api/v1/audio/play 的原始响应（例如通过
// adb forward tcp:18080 tcp:8080 从设备上取）。脚本会自己去 CDN 拉取音频流，
// 因此需要网络。

const fs = require('fs');
const crypto = require('crypto');
const https = require('https');

// 与 /internal/endpoints/video.go 的 spadeConstants 一致
const SPADE_CONSTANTS = Buffer.from([
  244, 155, 175, 127, 8, 232, 214, 141, 38, 167, 46, 55, 193, 169, 90, 47,
  31, 5, 165, 24, 146, 174, 242, 148, 151, 50, 182, 42, 56, 170, 221, 88,
]);

function spadeContentKey(spadeA) {
  const raw = Buffer.from(spadeA, 'base64');
  const outLen = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 0x2f;
  const buf = Buffer.from(raw.subarray(1, 1 + outLen));
  let prevA = 0x55;
  let prevB = 0xf6;
  const bitCount = (n) => n.toString(2).split('1').length - 1;
  for (let i = 0; i < buf.length; i++) {
    const cur = buf[i];
    let keep;
    if (i & 1) {
      keep = cur;
    } else {
      keep = prevA;
      prevA = prevB;
      prevB = cur;
    }
    buf[i] = ((prevA ^ cur) - bitCount(i) - 0x15) & 0xff;
    prevA = keep;
  }
  return Buffer.from(buf.subarray(1, 33).toString('ascii'), 'hex');
}

// Container boxes whose children do not begin at the payload: FullBoxes carry
// version/flags, stsd adds an entry count, and sample entries have a
// media-kind-specific fixed prefix before their child boxes.
function childStart(data, box) {
  switch (box.kind) {
    case 'stsd':
      return box.payload + 8;
    case 'encv':
      return box.payload + 78;
    case 'enca':
      return box.payload + (data.readUInt16BE(box.payload + 8) === 1 ? 44 : 28);
    default:
      return box.payload;
  }
}

function dump(data, start, end, depth) {
  for (const box of boxes(data, start, end)) {
    console.log(`${'  '.repeat(depth)}${box.kind} (${box.end - box.payload} bytes)`);
    if (depth < 6 && ['moov', 'trak', 'mdia', 'minf', 'stbl', 'stsd', 'enca', 'encv', 'sinf', 'schi', 'frma'].includes(box.kind)) {
      dump(data, childStart(data, box), box.end, depth + 1);
    }
  }
}

function* boxes(data, start, end) {
  let pos = start;
  while (pos + 8 <= end) {
    let size = data.readUInt32BE(pos);
    const kind = data.subarray(pos + 4, pos + 8).toString('latin1');
    let header = 8;
    if (size === 1) {
      size = Number(data.readBigUInt64BE(pos + 8));
      header = 16;
    } else if (size === 0) {
      size = end - pos;
    }
    if (size < header || pos + size > end) return;
    yield { kind, payload: pos + header, end: pos + size };
    pos += size;
  }
}

function find(data, start, end, path) {
  for (const box of boxes(data, start, end)) {
    if (box.kind !== path[0]) continue;
    if (path.length === 1) return box;
    const got = find(data, childStart(data, box), box.end, path.slice(1));
    if (got) return got;
  }
  return null;
}

function fetchBuffer(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { 'User-Agent': 'com.xs.fm/632 (Linux; U; Android 15; zh_CN)' }, rejectUnauthorized: false }, (res) => {
        const parts = [];
        res.on('data', (c) => parts.push(c));
        res.on('end', () => resolve(Buffer.concat(parts)));
      })
      .on('error', reject);
  });
}

async function main() {
  if (process.argv.length < 3) {
    console.error('用法: node scripts/verify_audio_cenc.cjs <play-response.json>');
    process.exit(2);
  }
  const resp = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const row = resp.video_info.data.video_model_datas[0];
  const model = JSON.parse(row.video_model);
  const stream = model.video_list[0];
  const spadeA = stream.encrypt_info.spade_a;
  const key = spadeContentKey(spadeA);

  console.log(`item_id      : ${row.item_id}  (${model.media_type}, ${model.video_duration}s)`);
  console.log(`spade_a      : ${spadeA.slice(0, 24)}…`);
  console.log(`derived key  : ${key.toString('hex')}`);

  const data = await fetchBuffer(stream.main_url);
  console.log(`downloaded   : ${data.length.toLocaleString()} bytes`);

  const moov = find(data, 0, data.length, ['moov']);
  const stbl = ['trak', 'mdia', 'minf', 'stbl'];
  const tenc = find(data, moov.payload, moov.end, [...stbl, 'stsd', 'enca', 'sinf', 'schi', 'tenc']);
  const senc = find(data, moov.payload, moov.end, [...stbl, 'senc']);
  const stsz = find(data, moov.payload, moov.end, [...stbl, 'stsz']);
  const stsc = find(data, moov.payload, moov.end, [...stbl, 'stsc']);
  const stco = find(data, moov.payload, moov.end, [...stbl, 'stco']) ||
    find(data, moov.payload, moov.end, [...stbl, 'co64']);
  if (!tenc || !senc || !stsz || !stsc || !stco) {
    if (process.env.DUMP_BOXES) dump(data, moov.payload, moov.end, 0, 'moov');
    throw new Error(
      `missing a required box: tenc=${!!tenc} senc=${!!senc} stsz=${!!stsz} stsc=${!!stsc} stco=${!!stco}`
    );
  }

  const ivSize = data[tenc.payload + 7];
  const sencFlags = data.readUInt32BE(senc.payload) & 0xffffff;
  const sampleCount = data.readUInt32BE(senc.payload + 4);
  let pos = senc.payload + 8;
  const ivs = [];
  const subsampleCounts = [];
  for (let i = 0; i < sampleCount; i++) {
    ivs.push(Buffer.from(data.subarray(pos, pos + ivSize)));
    pos += ivSize;
    let n = 0;
    if (sencFlags & 2) {
      n = data.readUInt16BE(pos);
      pos += 2 + 6 * n;
    }
    subsampleCounts.push(n);
  }

  const uniform = data.readUInt32BE(stsz.payload + 4);
  const nSamples = data.readUInt32BE(stsz.payload + 8);
  const sizes = [];
  for (let i = 0; i < nSamples; i++) {
    sizes.push(uniform || data.readUInt32BE(stsz.payload + 12 + 4 * i));
  }

  const nStsc = data.readUInt32BE(stsc.payload + 4);
  const stscEntries = [];
  for (let i = 0; i < nStsc; i++) {
    const p = stsc.payload + 8 + 12 * i;
    stscEntries.push([data.readUInt32BE(p), data.readUInt32BE(p + 4)]);
  }
  const wide = stco.kind === 'co64';
  const nChunks = data.readUInt32BE(stco.payload + 4);
  const chunks = [];
  for (let i = 0; i < nChunks; i++) {
    chunks.push(
      wide
        ? Number(data.readBigUInt64BE(stco.payload + 8 + 8 * i))
        : data.readUInt32BE(stco.payload + 8 + 4 * i)
    );
  }

  const offsets = [];
  let index = 0;
  for (let ci = 0; ci < nChunks && index < nSamples; ci++) {
    let per = stscEntries[0][1];
    for (const [first, n] of stscEntries) if (ci + 1 >= first) per = n;
    let off = chunks[ci];
    for (let k = 0; k < per && index < nSamples; k++, index++) {
      offsets.push(off);
      off += sizes[index];
    }
  }

  console.log(`iv_size      : ${ivSize}   senc_flags=${sencFlags}  subsampled=${subsampleCounts.some((n) => n > 0)}`);
  console.log(`samples      : ${sizes.length}  ivs=${ivs.length}  offsets=${offsets.length}`);

  const total = Math.min(sizes.length, ivs.length, offsets.length);
  let ok = 0;
  let bad = 0;
  const heads = [];
  for (let i = 0; i < total; i++) {
    const sample = data.subarray(offsets[i], offsets[i] + sizes[i]);
    if (sample.length !== sizes[i]) {
      bad++;
      continue;
    }
    const counter = Buffer.alloc(16);
    ivs[i].copy(counter, 0);
    const cipher = crypto.createCipheriv('aes-128-ctr', key, counter);
    const head = Buffer.from(cipher.update(sample.subarray(0, 32)));
    if (i < 5) heads.push(head.subarray(0, 8).toString('hex'));
    // raw AAC 帧头前 3 bit：SCE=000 / CPE=001
    if ((head[0] & 0xe0) === 0x00 || (head[0] & 0xe0) === 0x20) ok++;
    else bad++;
  }

  console.log(`aac-like     : ${ok} ok / ${bad} bad`);
  console.log(`first heads  : ${heads.join(' ')}`);
  console.log(
    ok > 0 && bad === 0
      ? 'RESULT: PASS — 密钥正确，解密后每个样本都是合法 AAC 帧头'
      : 'RESULT: FAIL — 解密结果不符合预期'
  );
}

main().catch((error) => {
  console.error('ERR', error.message);
  process.exit(1);
});
