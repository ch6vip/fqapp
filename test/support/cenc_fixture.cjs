'use strict';

// Structural ISO BMFF fixtures. Sample payloads are synthetic bytes; real
// codec/frame verification lives in the separate FFmpeg integration test.
// Encryption is provided independently by Node/OpenSSL, never by native C.
const assert = require('node:assert/strict');
const { createCipheriv, createHash } = require('node:crypto');

const KEY = Buffer.from('00112233445566778899aabbccddeeff', 'hex');
const KID = Buffer.from('ffeeddccbbaa99887766554433221100', 'hex');
const SYSTEM_ID = Buffer.from('edef8ba979d64acea3c827dcd51d21ed', 'hex');

function u16(value) {
  const result = Buffer.alloc(2);
  result.writeUInt16BE(value);
  return result;
}
function u32(value) {
  const result = Buffer.alloc(4);
  result.writeUInt32BE(value);
  return result;
}
function u64(value) {
  const result = Buffer.alloc(8);
  result.writeBigUInt64BE(BigInt(value));
  return result;
}
function box(type, payload = Buffer.alloc(0), extended = false) {
  assert.equal(type.length, 4);
  const header = Buffer.alloc(extended ? 16 : 8);
  header.writeUInt32BE(extended ? 1 : header.length + payload.length);
  header.write(type, 4, 4, 'latin1');
  if (extended) header.writeBigUInt64BE(BigInt(header.length + payload.length), 8);
  return Buffer.concat([header, payload]);
}
function payload(length, salt = 0) {
  const result = Buffer.alloc(length);
  for (let index = 0; index < length; ++index) {
    result[index] = (index * 37 + (index >>> 8) * 11 + salt * 53 + 19) & 255;
  }
  return result;
}

// This walker is used to locate fields for fixtures and deliberate corruptions,
// not to calculate expected plaintext or to validate the native parser output.
function boxes(buffer) {
  const found = [];
  const containers = new Set(['moov', 'trak', 'mdia', 'minf', 'stbl', 'dinf', 'sinf', 'schi']);
  function visit(start, end, parent = null) {
    for (let position = start; position < end;) {
      assert.ok(end - position >= 8, 'fixture box header');
      let size = buffer.readUInt32BE(position);
      const type = buffer.toString('latin1', position + 4, position + 8);
      let header = 8;
      if (size === 1) {
        assert.ok(end - position >= 16, 'fixture extended box header');
        size = Number(buffer.readBigUInt64BE(position + 8));
        header = 16;
      } else if (size === 0) size = end - position;
      assert.ok(Number.isSafeInteger(size) && size >= header && size <= end - position,
        `fixture ${type} box length`);
      const entry = { type, start: position, payload: position + header,
        end: position + size, size, header, parent };
      found.push(entry);
      let children;
      if (containers.has(type)) children = entry.payload;
      else if (type === 'stsd' || type === 'dref') children = entry.payload + 8;
      else if (['encv', 'avc1', 'hvc1', 'hev1'].includes(type)) children = entry.payload + 78;
      else if (type === 'enca' || type === 'mp4a') {
        children = entry.payload + (buffer.readUInt16BE(entry.payload + 8) === 1 ? 44 : 28);
      }
      if (children !== undefined) {
        assert.ok(children <= entry.end, `fixture ${type} fields`);
        visit(children, entry.end, entry);
      }
      position += size;
    }
  }
  visit(0, buffer.length);
  return found;
}

function encryptSample(plain, iv, subsamples) {
  const initial = Buffer.alloc(16);
  iv.copy(initial);
  const cipher = createCipheriv('aes-128-ctr', KEY, initial);
  if (!subsamples || subsamples.length === 0) {
    return Buffer.concat([cipher.update(plain), cipher.final()]);
  }
  const encryptedParts = [];
  let position = 0;
  for (const [clear, encrypted] of subsamples) {
    assert.ok(clear >= 0 && clear <= 65535 && encrypted >= 0);
    position += clear;
    encryptedParts.push(plain.subarray(position, position + encrypted));
    position += encrypted;
  }
  assert.equal(position, plain.length, 'subsamples cover the input sample');
  const encrypted = Buffer.concat([
    cipher.update(Buffer.concat(encryptedParts)), cipher.final(),
  ]);
  const result = Buffer.from(plain);
  position = 0;
  let consumed = 0;
  for (const [clear, length] of subsamples) {
    position += clear;
    encrypted.copy(result, position, consumed, consumed + length);
    position += length;
    consumed += length;
  }
  return result;
}

function normalizeTrack(input, trackIndex) {
  const track = { ...input };
  track.kind ||= 'video';
  track.codec ||= track.kind === 'audio' ? 'mp4a' : 'avc1';
  track.encrypted = input.encrypted !== false;
  track.ivSize ||= 8;
  track.kid = Buffer.from(input.kid || KID);
  track.samples = (input.samples || [{ size: 73 }, { size: 117 }, { size: 31 }]).map((item, sampleIndex) => {
    const sample = typeof item === 'number' ? { size: item } : { ...item };
    sample.plain = sample.plain ? Buffer.from(sample.plain)
      : payload(sample.size, trackIndex * 17 + sampleIndex);
    sample.size = sample.plain.length;
    sample.iv = sample.iv ? Buffer.from(sample.iv)
      : createHash('sha256').update(`fixture-iv-${trackIndex}-${sampleIndex}`).digest().subarray(0, track.ivSize);
    assert.equal(sample.iv.length, track.ivSize);
    sample.cipher = track.encrypted ? encryptSample(sample.plain, sample.iv, sample.subsamples)
      : Buffer.from(sample.plain);
    return sample;
  });
  track.subsampleEncryption = input.subsampleEncryption === true ||
    track.samples.some((sample) => sample.subsamples !== undefined);
  const counts = input.chunks || track.samples.map(() => 1);
  assert.equal(counts.reduce((sum, count) => sum + count, 0), track.samples.length);
  let first = 0;
  track.chunks = counts.map((count) => {
    assert.ok(count > 0);
    const samples = track.samples.slice(first, first + count);
    const chunk = { trackIndex, first, count, samples, offset: 0,
      cipher: Buffer.concat(samples.map((sample) => sample.cipher)),
      plain: Buffer.concat(samples.map((sample) => sample.plain)) };
    first += count;
    return chunk;
  });
  track.auxiliary = track.encrypted && input.auxiliary !== false;
  track.auxiliaryOffset = 0;
  return track;
}

function makeFixture(options = {}) {
  const extended = options.extended === true;
  const B = (type, ...parts) => box(type, Buffer.concat(parts), extended);
  const F = (type, version, flags, ...parts) => B(type, u32(version * 0x1000000 + flags), ...parts);
  const tracks = (options.tracks || [{}]).map(normalizeTrack);

  function pssh(version, clear) {
    const data = Buffer.from('fixture DRM initialization data');
    const ids = version === 1 ? Buffer.concat([u32(2), KID, Buffer.alloc(16, 0x5a)]) : Buffer.alloc(0);
    return F(clear ? 'free' : 'pssh', version, 0, SYSTEM_ID, ids, u32(data.length), data);
  }

  function sampleEntry(track, clear) {
    const audio = track.kind === 'audio';
    const fields = Buffer.alloc(audio ? (track.audioVersion === 1 ? 44 : 28) : 78);
    fields.writeUInt16BE(1, 6); // Self-contained data reference index.
    if (audio) {
      fields.writeUInt16BE(track.audioVersion || 0, 8);
      fields.writeUInt16BE(2, 16);
      fields.writeUInt16BE(16, 18);
      fields.writeUInt32BE(48000 * 65536, 24);
      if (track.audioVersion === 1) fields.writeUInt32BE(1024, 28);
    } else {
      fields.writeUInt16BE(480, 24);
      fields.writeUInt16BE(270, 26);
      fields.writeUInt32BE(72 * 65536, 28);
      fields.writeUInt32BE(72 * 65536, 32);
      fields.writeUInt16BE(1, 40);
      fields.writeUInt16BE(24, 74);
      fields.writeUInt16BE(65535, 76);
    }
    const configuration = audio ? F('esds', 0, 0, Buffer.from('030004004005021190060102', 'hex'))
      : B(track.codec === 'avc1' ? 'avcC' : 'hvcC', payload(track.codec === 'avc1' ? 7 : 23, 11));
    const extra = [];
    if (track.encrypted) {
      const tenc = F('tenc', track.tencVersion || 0, 0,
        Buffer.from([0, 0, 1, track.ivSize]), track.kid);
      extra.push(B(clear ? 'free' : 'sinf', B('frma', Buffer.from(track.codec)),
        F('schm', 0, 0, Buffer.from('cenc'), u32(0x10000)), B('schi', tenc)));
    }
    const type = track.encrypted && !clear ? (audio ? 'enca' : 'encv') : track.codec;
    return B(type, fields, configuration, ...extra);
  }

  function makeTrack(track, clear) {
    const sampleSizes = track.samples.map((sample) => sample.size);
    let sizeBody;
    if (track.fixedSize) {
      assert.ok(sampleSizes.length > 0 && sampleSizes[0] > 0);
      assert.ok(sampleSizes.every((size) => size === sampleSizes[0]));
      sizeBody = Buffer.concat([u32(sampleSizes[0]), u32(sampleSizes.length)]);
    } else sizeBody = Buffer.concat([u32(0), u32(sampleSizes.length), ...sampleSizes.map(u32)]);
    const mappings = [];
    for (let index = 0; index < track.chunks.length; ++index) {
      if (index === 0 || track.chunks[index].count !== track.chunks[index - 1].count) {
        mappings.push(u32(index + 1), u32(track.chunks[index].count), u32(1));
      }
    }
    const chunkOffsets = track.chunks.map((chunk) => track.co64 ? u64(chunk.offset) : u32(chunk.offset));
    const tables = [
      F('stsd', 0, 0, u32(1), sampleEntry(track, clear)),
      F('stts', 0, 0, u32(sampleSizes.length ? 1 : 0),
        ...(sampleSizes.length ? [u32(sampleSizes.length), u32(1000)] : [])),
      F('stsz', 0, 0, sizeBody),
      F('stsc', 0, 0, u32(mappings.length / 3), ...mappings),
      F(track.co64 ? 'co64' : 'stco', 0, 0, u32(chunkOffsets.length), ...chunkOffsets),
    ];
    if (track.encrypted) {
      const records = track.samples.map((sample) => Buffer.concat([
        sample.iv,
        ...(track.subsampleEncryption ? [u16((sample.subsamples || []).length),
          ...(sample.subsamples || []).flatMap(([clearBytes, encryptedBytes]) => [u16(clearBytes), u32(encryptedBytes)])] : []),
      ]));
      tables.push(F(clear ? 'free' : 'senc', 0, track.subsampleEncryption ? 2 : 0,
        u32(records.length), ...records));
      if (track.auxiliary) {
        assert.ok(records.every((record) => record.length <= 255));
        const fixed = !track.auxiliaryVariable && records.length > 0 &&
          records.every((record) => record.length === records[0].length) ? records[0].length : 0;
        const info = track.auxiliaryType ? [Buffer.from('cenc'), u32(0)] : [];
        const offsetCount = records.length ? 1 : 0;
        tables.push(F(clear ? 'free' : 'saiz', 0, track.auxiliaryType ? 1 : 0,
          ...info, Buffer.from([fixed]), u32(records.length),
          ...(fixed ? [] : [Buffer.from(records.map((record) => record.length))])));
        tables.push(F(clear ? 'free' : 'saio', track.auxiliaryOffset64 ? 1 : 0,
          track.auxiliaryType ? 1 : 0, ...info, u32(offsetCount),
          ...(offsetCount ? [track.auxiliaryOffset64 ? u64(track.auxiliaryOffset) : u32(track.auxiliaryOffset)] : [])));
      }
    }
    const dinf = B('dinf', F('dref', 0, 0, u32(1), F('url ', 0, 1)));
    const mediaHeader = track.kind === 'audio' ? F('smhd', 0, 0, Buffer.alloc(4))
      : F('vmhd', 0, 1, Buffer.alloc(8));
    const handler = F('hdlr', 0, 0, u32(0), Buffer.from(track.kind === 'audio' ? 'soun' : 'vide'),
      Buffer.alloc(12), Buffer.from('fixture\0'));
    const mdhd = F('mdhd', 0, 0, u32(0), u32(0), u32(1000), u32(sampleSizes.length * 1000), u16(0x55c4), u16(0));
    const tkhd = F('tkhd', 0, 3, Buffer.alloc(80));
    return B('trak', tkhd, B('mdia', mdhd, handler, B('minf', mediaHeader, dinf, B('stbl', ...tables))));
  }

  function makeMoov(clear) {
    return B('moov', F('mvhd', 0, 0, Buffer.alloc(96)), ...tracks.map((track) => makeTrack(track, clear)),
      ...(options.pssh ? [pssh(0, clear), pssh(1, clear)] : []));
  }

  const chunkOrder = [];
  const maxChunks = Math.max(0, ...tracks.map((track) => track.chunks.length));
  for (let index = 0; index < maxChunks; ++index) {
    for (const track of tracks) if (track.chunks[index]) chunkOrder.push(track.chunks[index]);
  }
  const mediaCount = options.mdatCount || 1;
  assert.ok(mediaCount >= 1 && mediaCount <= 8);
  const media = Array.from({ length: mediaCount }, (_, index) => ({
    chunks: [], prefix: payload(23 + index, 99 + index), suffix: payload(11, 107 + index), start: 0,
  }));
  chunkOrder.forEach((chunk, index) => media[index % mediaCount].chunks.push(chunk));
  function makeMdat(group, clear) {
    return B('mdat', group.prefix, ...group.chunks.map((chunk) => clear ? chunk.plain : chunk.cipher), group.suffix);
  }
  const ftyp = B('ftyp', Buffer.from('isom'), u32(512), Buffer.from('isomiso2avc1mp41'));
  const parts = [{ kind: 'fixed', buffer: ftyp }];
  if (options.pssh) parts.push({ kind: 'pssh', version: 0 });
  if (!options.tailMoov) parts.push({ kind: 'moov' });
  media.forEach((group, index) => {
    if (index) parts.push({ kind: 'fixed', buffer: B('free', payload(17, index)) });
    parts.push({ kind: 'mdat', group });
  });
  if (options.pssh) parts.push({ kind: 'pssh', version: 1 });
  if (options.tailMoov) parts.push({ kind: 'moov' });
  parts.push({ kind: 'fixed', buffer: B('free', payload(13, 51)) });

  let moovOffset = 0;
  const provisionalMoov = makeMoov(false);
  let position = 0;
  for (const part of parts) {
    if (part.kind === 'moov') {
      moovOffset = position;
      position += provisionalMoov.length;
    } else if (part.kind === 'mdat') {
      part.group.start = position;
      let offset = position + (extended ? 16 : 8) + part.group.prefix.length;
      for (const chunk of part.group.chunks) {
        chunk.offset = offset;
        let sampleOffset = offset;
        for (const sample of chunk.samples) {
          sample.offset = sampleOffset;
          sampleOffset += sample.size;
        }
        offset += chunk.cipher.length;
      }
      position += makeMdat(part.group, false).length;
    } else position += part.kind === 'pssh' ? pssh(part.version, false).length : part.buffer.length;
  }
  const sencBoxes = boxes(makeMoov(false)).filter((entry) => entry.type === 'senc');
  let encryptedTrack = 0;
  for (const track of tracks) {
    if (track.encrypted) track.auxiliaryOffset = moovOffset + sencBoxes[encryptedTrack++].payload + 8;
  }
  function assemble(clear) {
    return Buffer.concat(parts.map((part) => {
      if (part.kind === 'fixed') return part.buffer;
      if (part.kind === 'moov') return makeMoov(clear);
      if (part.kind === 'mdat') return makeMdat(part.group, clear);
      return pssh(part.version, clear);
    }));
  }
  const encrypted = assemble(false);
  const expected = assemble(true);
  assert.equal(encrypted.length, expected.length);
  return { encrypted, expected, tracks, media, moovOffset, boxes: boxes(encrypted), key: Buffer.from(KEY) };
}

module.exports = { makeFixture, boxes, box, payload, u16, u32, u64, KEY, KID };
