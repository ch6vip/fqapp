'use strict';

// Offline metadata checks plus a bounded HTTPS download of CENC AAC audio.
// Usage: node scripts/verify_audio_cenc.cjs <play-response.json>
//
// The response is GET /api/v1/audio/play's video_info envelope. Derive its
// spade_a key, validate one complete encrypted AAC track, and check every
// sample's first element type after CTR decryption. AAC-head matching is only
// a heuristic: it neither decodes AAC nor authenticates the stream or key.
// See .agents/notes/implemented/bug-fix/2026-09-16-cross-review-boundaries.md.
const fs = require('node:fs');
const crypto = require('node:crypto');
const https = require('node:https');

const MAX_SAMPLES = 1000000;
const MAX_SUBSAMPLES = 2000000;

function check(condition, message) {
  if (!condition) throw new Error(message);
}

function spadeContentKey(spadeA) {
  check(typeof spadeA === 'string' && spadeA.length <= 65536, 'Invalid spade key');
  const encoded = spadeA.trim().replace(/-/g, '+').replace(/_/g, '/');
  check(/^[A-Za-z0-9+/]+={0,2}$/.test(encoded), 'Invalid spade base64');
  const raw = Buffer.from(encoded, 'base64');
  const canonical = raw.toString('base64');
  check(raw.length >= 3 && (encoded === canonical || encoded === canonical.replace(/=+$/, '')),
  'Invalid spade base64');
  const outLen = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 0x2f;
  check(outLen >= 33 && outLen <= raw.length - 1, 'Invalid spade length');
  const decoded = Buffer.from(raw.subarray(1, 1 + outLen));
  let prevA = 0x55;
  let prevB = 0xf6;
  for (let i = 0; i < decoded.length; i++) {
    const cur = decoded[i];
    const keep = i & 1 ? cur : prevA;
    if (!(i & 1)) {
      prevA = prevB;
      prevB = cur;
    }
    const bitCount = i.toString(2).split('1').length - 1;
    decoded[i] = ((prevA ^ cur) - bitCount - 0x15) & 0xff;
    prevA = keep;
  }
  // latin1 preserves high bits; ASCII decoding would mask malformed key bytes.
  const hex = decoded.subarray(1, 33).toString('latin1');
  check(/^[0-9a-fA-F]{32}$/.test(hex), 'Invalid derived AES-128 key');
  return Buffer.from(hex, 'hex');
}

function fetchBuffer(url, { maxBytes = 64 * 1024 * 1024, timeoutMs = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    let request;
    let response;
    let timer;
    let settled = false;
    const parts = [];
    const finish = (error, data) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) {
        response?.destroy();
        request?.destroy();
        parts.length = 0;
        reject(error);
      } else resolve(data);
    };
    const fail = error => finish(error);
    try {
      check(Number.isSafeInteger(maxBytes) && maxBytes > 0, 'Invalid download byte limit');
      check(Number.isSafeInteger(timeoutMs) && timeoutMs > 0 && timeoutMs <= 2147483647,
        'Invalid download timeout');
      const target = new URL(url);
      check(target.protocol === 'https:', 'Audio URL must use HTTPS');
      check(!target.username && !target.password, 'Audio URL must not contain credentials');
      // This is a total deadline, including DNS/TLS and continuously dripping data.
      timer = setTimeout(() => fail(new Error('Audio download timed out')), timeoutMs);
      request = https.get(target, {
        rejectUnauthorized: true,
        headers: {
          'User-Agent': 'com.xs.fm/632 (Linux; U; Android 15; zh_CN)',
          'Accept-Encoding': 'identity',
        },
      }, res => {
        response = res;
        res.on('error', fail);
        res.on('aborted', () => fail(new Error('Audio response aborted')));
        res.on('close', () => {
          if (!settled) fail(new Error('Incomplete audio response'));
        });
        if (settled) { res.destroy(); return; }
        try {
          check(res.statusCode === 200, 'Audio download HTTP status ' + res.statusCode);
          const encoding = res.headers['content-encoding'];
          check(encoding == null || encoding === 'identity', 'Unsupported content encoding');
          const lengthHeader = res.headers['content-length'];
          let declaredLength = null;
          if (lengthHeader != null) {
            check(typeof lengthHeader === 'string' && /^\d+$/.test(lengthHeader),
              'Invalid Content-Length');
            declaredLength = Number(lengthHeader);
            check(Number.isSafeInteger(declaredLength) && declaredLength > 0,
              'Invalid Content-Length');
            check(declaredLength <= maxBytes, 'Content-Length exceeds download limit');
          }
          let received = 0;
          res.on('data', chunk => {
            if (settled) return;
            received += chunk.length;
            if (received > maxBytes || (declaredLength != null && received > declaredLength)) {
              fail(new Error('Audio body exceeds length or download limit'));
              return;
            }
            parts.push(chunk);
          });
          res.on('end', () => {
            if (settled) return;
            if (res.complete === false || received === 0 ||
                (declaredLength != null && received !== declaredLength)) {
              fail(new Error('Incomplete audio body or Content-Length mismatch'));
              return;
            }
            finish(null, Buffer.concat(parts, received));
          });
        } catch (error) { fail(error); }
      });
      request.on('error', fail);
    } catch (error) { fail(error); }
  });
}

function bytes(data, start, length, end) {
  check(Number.isSafeInteger(start) && Number.isSafeInteger(length) &&
    start >= 0 && length >= 0 && start <= end && length <= end - start &&
    end <= data.length, 'Truncated or invalid MP4 metadata');
}

function* boxes(data, start = 0, end = data.length) {
  bytes(data, start, end - start, end);
  let count = 0;
  for (let pos = start; pos < end;) {
    check(++count <= 100000, 'Too many MP4 boxes');
    bytes(data, pos, 8, end);
    let size = data.readUInt32BE(pos);
    const kind = data.toString('latin1', pos + 4, pos + 8);
    let header = 8;
    if (size === 1) {
      bytes(data, pos, 16, end);
      size = Number(data.readBigUInt64BE(pos + 8));
      header = 16;
    } else if (size === 0) size = end - pos;
    check(Number.isSafeInteger(size) && size >= header && size <= end - pos,
      'Invalid ' + kind + ' box size');
    yield { kind, payload: pos + header, end: pos + size };
    pos += size;
  }
}

function children(data, box, prefix = 0) {
  bytes(data, box.payload, prefix, box.end);
  return [...boxes(data, box.payload + prefix, box.end)];
}

// Keep the existing opt-in box diagnostic, using the same bounded walker.
function dump(data, start = 0, end = data.length, depth = 0) {
  for (const box of boxes(data, start, end)) {
    console.log('  '.repeat(depth) + box.kind + ' (' + (box.end - box.payload) + ' bytes)');
    if (depth >= 8) continue;
    let prefix;
    if (['moov', 'trak', 'mdia', 'minf', 'stbl', 'sinf', 'schi'].includes(box.kind)) prefix = 0;
    else if (box.kind === 'stsd') prefix = 8;
    else if (box.kind === 'encv') prefix = 78;
    else if (box.kind === 'enca') {
      bytes(data, box.payload, 10, box.end);
      prefix = data.readUInt16BE(box.payload + 8) === 1 ? 44 : 28;
    }
    if (prefix != null) {
      bytes(data, box.payload, prefix, box.end);
      dump(data, box.payload + prefix, box.end, depth + 1);
    }
  }
}

function one(list, kind, required = true) {
  const matches = list.filter(box => box.kind === kind);
  check(matches.length <= 1 && (!required || matches.length === 1),
    'Missing or duplicate ' + kind + ' box');
  return matches[0];
}

function fullBox(data, box, versions = [0], allowedFlags = 0) {
  bytes(data, box.payload, 4, box.end);
  const version = data[box.payload];
  const flags = data.readUInt32BE(box.payload) & 0xffffff;
  check(versions.includes(version) && (flags & ~allowedFlags) === 0,
    'Unsupported ' + box.kind + ' version or flags');
  return { version, flags };
}

function exactSize(box, size) {
  check(box.end - box.payload === size, 'Invalid ' + box.kind + ' payload length');
}

function audioTables(data, roots) {
  check(!roots.some(box => box.kind === 'moof'), 'Fragmented MP4 is unsupported');
  const moov = one(roots, 'moov');
  const moovChildren = children(data, moov);
  check(!moovChildren.some(box => box.kind === 'mvex'), 'Fragmented MP4 is unsupported');
  const tracks = moovChildren.filter(box => box.kind === 'trak');
  check(tracks.length <= 32, 'Too many MP4 tracks');
  const found = [];
  for (const trak of tracks) {
    const mdia = one(children(data, trak), 'mdia');
    const media = children(data, mdia);
    const hdlr = one(media, 'hdlr');
    fullBox(data, hdlr);
    bytes(data, hdlr.payload, 24, hdlr.end);
    if (data.toString('latin1', hdlr.payload + 8, hdlr.payload + 12) !== 'soun') continue;
    const mediaInfo = children(data, one(media, 'minf'));
    const stbl = one(mediaInfo, 'stbl');
    const tables = children(data, stbl);
    for (const box of tables) {
      if (box.kind === 'sgpd' || box.kind === 'sbgp') {
        fullBox(data, box, box.kind === 'sgpd' ? [0, 1, 2] : [0, 1]);
        bytes(data, box.payload, 8, box.end);
        check(data.toString('latin1', box.payload + 4, box.payload + 8) !== 'seig',
          'Sample encryption group overrides are unsupported');
      } else if (box.kind === 'uuid') {
        bytes(data, box.payload, 16, box.end);
        check(data.toString('hex', box.payload, box.payload + 16) !== 'a2394f525a9b4f14a2446c427c648df4',
          'PIFF sample encryption is unsupported');
      }
    }
    const stsd = one(tables, 'stsd');
    fullBox(data, stsd);
    const entries = children(data, stsd, 8);
    check(data.readUInt32BE(stsd.payload + 4) === entries.length, 'Invalid stsd entry count');
    if (!entries.some(entry => entry.kind === 'enca')) continue;
    check(entries.length === 1, 'Multiple audio sample descriptions are unsupported');
    const entry = entries[0];
    bytes(data, entry.payload, 28, entry.end);
    const audioVersion = data.readUInt16BE(entry.payload + 8);
    check(audioVersion <= 1, 'Unsupported audio sample entry version');
    check(data.readUInt16BE(entry.payload + 6) === 1, 'External media data is unsupported');
    const dinf = one(mediaInfo, 'dinf', false);
    if (dinf) {
      const dref = one(children(data, dinf), 'dref');
      fullBox(data, dref);
      const references = children(data, dref, 8);
      check(references.length > 0 && data.readUInt32BE(dref.payload + 4) === references.length,
        'Invalid data reference count');
      const reference = references[0];
      check(reference.kind === 'url ', 'External media data is unsupported');
      exactSize(reference, 4);
      check(fullBox(data, reference, [0], 1).flags === 1, 'External media data is unsupported');
    }
    const sinf = one(children(data, entry, audioVersion === 1 ? 44 : 28), 'sinf');
    const protection = children(data, sinf);
    const frma = one(protection, 'frma');
    exactSize(frma, 4);
    check(data.toString('latin1', frma.payload, frma.end) === 'mp4a', 'Expected encrypted AAC');
    const schm = one(protection, 'schm');
    fullBox(data, schm);
    exactSize(schm, 12);
    check(data.toString('latin1', schm.payload + 4, schm.payload + 8) === 'cenc',
      'Only CENC AES-CTR is supported');
    const tenc = one(children(data, one(protection, 'schi')), 'tenc');
    fullBox(data, tenc, [0, 1]);
    exactSize(tenc, 24);
    const ivSize = data[tenc.payload + 7];
    check(data[tenc.payload + 4] === 0 && data[tenc.payload + 5] === 0 &&
      data[tenc.payload + 6] === 1 && [8, 16].includes(ivSize),
    'Unsupported tenc protection, pattern, or IV size');
    found.push({ tables, ivSize });
  }
  check(found.length === 1, 'Expected exactly one encrypted AAC track');
  return found[0];
}

function sampleLayout(data, tables, mdats) {
  const stsz = one(tables, 'stsz');
  fullBox(data, stsz);
  bytes(data, stsz.payload, 12, stsz.end);
  const uniform = data.readUInt32BE(stsz.payload + 4);
  const count = data.readUInt32BE(stsz.payload + 8);
  check(count > 0 && count <= MAX_SAMPLES, 'Invalid or excessive sample count');
  exactSize(stsz, 12 + (uniform ? 0 : count * 4));
  const sizes = new Uint32Array(count);
  for (let i = 0; i < count; i++) {
    sizes[i] = uniform || data.readUInt32BE(stsz.payload + 12 + i * 4);
    check(sizes[i] > 0, 'Empty audio sample');
  }
  const stco = one(tables, 'stco', false);
  const co64 = one(tables, 'co64', false);
  check(!!stco !== !!co64, 'Expected one chunk offset table');
  const offsetsBox = stco || co64;
  fullBox(data, offsetsBox);
  bytes(data, offsetsBox.payload, 8, offsetsBox.end);
  const chunks = data.readUInt32BE(offsetsBox.payload + 4);
  const width = stco ? 4 : 8;
  check(chunks > 0 && chunks <= count, 'Invalid chunk count');
  exactSize(offsetsBox, 8 + chunks * width);
  const stsc = one(tables, 'stsc');
  fullBox(data, stsc);
  bytes(data, stsc.payload, 8, stsc.end);
  const mappings = data.readUInt32BE(stsc.payload + 4);
  check(mappings > 0 && mappings <= chunks, 'Invalid stsc count');
  exactSize(stsc, 8 + mappings * 12);
  const mapping = i => {
    const pos = stsc.payload + 8 + i * 12;
    return [data.readUInt32BE(pos), data.readUInt32BE(pos + 4), data.readUInt32BE(pos + 8)];
  };
  let previous = 0;
  for (let i = 0; i < mappings; i++) {
    const [first, per, description] = mapping(i);
    check(first > previous && first <= chunks && (i !== 0 || first === 1) &&
      per > 0 && per <= count && description === 1, 'Invalid stsc mapping');
    previous = first;
  }
  const offsets = new Float64Array(count);
  const ranges = [];
  let index = 0;
  let mi = 0;
  let per = mapping(0)[1];
  for (let ci = 0; ci < chunks; ci++) {
    if (mi + 1 < mappings && mapping(mi + 1)[0] === ci + 1) per = mapping(++mi)[1];
    check(per <= count - index, 'Chunk mapping exceeds sample count');
    const pos = offsetsBox.payload + 8 + ci * width;
    const start = width === 4 ? data.readUInt32BE(pos) : Number(data.readBigUInt64BE(pos));
    check(Number.isSafeInteger(start) && start <= data.length, 'Invalid chunk offset');
    let end = start;
    for (let n = 0; n < per; n++, index++) {
      offsets[index] = end;
      end += sizes[index];
      check(end <= data.length, 'Sample outside media data');
    }
    // MDAT boxes are ordered by file position; avoid scanning all of them per sample.
    let lo = 0;
    let hi = mdats.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (mdats[mid].payload <= start) lo = mid + 1;
      else hi = mid;
    }
    check(lo > 0 && end <= mdats[lo - 1].end, 'Sample outside media data');
    ranges.push({ start, end });
  }
  check(index === count, 'Chunk mapping omits samples');
  ranges.sort((a, b) => a.start - b.start);
  for (let i = 1; i < ranges.length; i++) {
    check(ranges[i].start >= ranges[i - 1].end, 'Overlapping audio chunks');
  }
  return { sizes, offsets, count };
}

function auxiliarySizes(data, tables, senc, count) {
  const saiz = one(tables, 'saiz', false);
  const saio = one(tables, 'saio', false);
  check(!!saiz === !!saio, 'Incomplete encryption auxiliary tables');
  if (!saiz) return null;
  const prefix = box => {
    const info = fullBox(data, box, box.kind === 'saio' ? [0, 1] : [0], 1);
    const pos = box.payload + 4;
    if (info.flags & 1) {
      bytes(data, pos, 8, box.end);
      check(data.toString('latin1', pos, pos + 4) === 'cenc' &&
        data.readUInt32BE(pos + 4) === 0, 'Unsupported encryption auxiliary type');
    }
    return { pos: pos + (info.flags & 1 ? 8 : 0), version: info.version };
  };
  const sizeInfo = prefix(saiz);
  bytes(data, sizeInfo.pos, 5, saiz.end);
  const uniform = data[sizeInfo.pos];
  check(data.readUInt32BE(sizeInfo.pos + 1) === count, 'saiz sample count mismatch');
  check(saiz.end === sizeInfo.pos + 5 + (uniform ? 0 : count), 'Invalid saiz length');
  const offsetInfo = prefix(saio);
  const width = offsetInfo.version === 1 ? 8 : 4;
  bytes(data, offsetInfo.pos, 4 + width, saio.end);
  check(saio.end === offsetInfo.pos + 4 + width &&
    data.readUInt32BE(offsetInfo.pos) === 1, 'Unsupported saio entries');
  const offset = width === 4 ? data.readUInt32BE(offsetInfo.pos + 4)
    : Number(data.readBigUInt64BE(offsetInfo.pos + 4));
  check(offset === senc.payload + 8, 'saio does not address senc records');
  return i => uniform || data[sizeInfo.pos + 5 + i];
}

function verifyAudio(data, key) {
  check(Buffer.isBuffer(key) && key.length === 16, 'Expected an AES-128 key');
  const roots = [...boxes(data)];
  const { tables, ivSize } = audioTables(data, roots);
  const { sizes, offsets, count } = sampleLayout(data, tables,
    roots.filter(box => box.kind === 'mdat'));
  const senc = one(tables, 'senc');
  const { flags } = fullBox(data, senc, [0], 2);
  bytes(data, senc.payload, 8, senc.end);
  check(data.readUInt32BE(senc.payload + 4) === count, 'senc sample count mismatch');
  const auxiliarySize = auxiliarySizes(data, tables, senc, count);
  let pos = senc.payload + 8;
  let subsamples = 0;
  let ok = 0;
  let bad = 0;
  const heads = [];
  for (let i = 0; i < count; i++) {
    const recordStart = pos;
    bytes(data, pos, ivSize, senc.end);
    const counter = Buffer.alloc(16);
    data.copy(counter, 0, pos, pos + ivSize);
    pos += ivSize;
    let entries = 0;
    if (flags & 2) {
      bytes(data, pos, 2, senc.end);
      entries = data.readUInt16BE(pos);
      pos += 2;
    }
    subsamples += entries;
    check(subsamples <= MAX_SUBSAMPLES, 'Too many encryption subsamples');
    bytes(data, pos, entries * 6, senc.end);
    const cipher = crypto.createDecipheriv('aes-128-ctr', key, counter);
    let head = Buffer.from(data.subarray(offsets[i], offsets[i] + Math.min(32, sizes[i])));
    if (entries === 0) head = cipher.update(head);
    else {
      let samplePos = 0;
      for (let n = 0; n < entries; n++, pos += 6) {
        samplePos += data.readUInt16BE(pos);
        const encrypted = data.readUInt32BE(pos + 2);
        check(samplePos <= sizes[i] && encrypted <= sizes[i] - samplePos,
          'Subsample exceeds audio sample');
        const end = Math.min(head.length, samplePos + encrypted);
        if (samplePos < end) {
          // Clear bytes do not consume the CTR keystream.
          cipher.update(head.subarray(samplePos, end)).copy(head, samplePos);
        }
        samplePos += encrypted;
      }
      check(samplePos === sizes[i], 'Subsamples do not cover the audio sample');
    }
    if (auxiliarySize) check(auxiliarySize(i) === pos - recordStart,
      'saiz record length mismatch');
    if (i < 5) heads.push(head.subarray(0, 8).toString('hex'));
    if ((head[0] & 0xe0) === 0 || (head[0] & 0xe0) === 0x20) ok++;
    else bad++;
  }
  check(pos === senc.end, 'Trailing or inconsistent senc records');
  return { count, ivSize, flags, subsamples, ok, bad, heads };
}

async function main() {
  if (process.argv.length !== 3) {
    console.error('Usage: node scripts/verify_audio_cenc.cjs <play-response.json>');
    process.exitCode = 2;
    return;
  }
  check(fs.statSync(process.argv[2]).size <= 4 * 1024 * 1024, 'Response JSON exceeds size limit');
  const resp = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const row = resp?.video_info?.data?.video_model_datas?.[0];
  check(row && typeof row.video_model === 'string', 'Missing audio video_model');
  const model = JSON.parse(row.video_model);
  const stream = model?.video_list?.[0];
  check(stream && typeof stream.main_url === 'string', 'Missing audio stream URL');
  const key = spadeContentKey(stream.encrypt_info?.spade_a);
  console.log('item_id      : ' + row.item_id);
  console.log('derived key  : ' + key.length + ' bytes (value omitted)');
  const data = await fetchBuffer(stream.main_url);
  console.log('downloaded   : ' + data.length.toLocaleString() + ' bytes');
  let result;
  try { result = verifyAudio(data, key); }
  catch (error) {
    if (process.env.DUMP_BOXES) {
      try { dump(data); } catch (_) { /* Preserve the original validation error. */ }
    }
    throw error;
  }
  console.log('iv_size      : ' + result.ivSize + '   senc_flags=' + result.flags +
    '  subsampled=' + (result.subsamples > 0));
  console.log('samples      : ' + result.count + ' (all checked)');
  console.log('aac-like     : ' + result.ok + ' ok / ' + result.bad + ' bad');
  console.log('first heads  : ' + result.heads.join(' '));
  if (result.bad === 0) {
    console.log('RESULT: PASS — AAC-head heuristic only; full AAC decoding and integrity are not verified');
  } else {
    console.log('RESULT: FAIL — decrypted sample heads do not match the AAC heuristic');
    process.exitCode = 1;
  }
}

if (require.main === module) main().catch(error => {
  console.error('ERR', error.message);
  process.exitCode = 1;
});
