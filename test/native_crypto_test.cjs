'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { before, test } = require('node:test');
const { makeFixture, box, KID } = require('./support/cenc_fixture.cjs');
const { compileDriver } = require('./support/native_compile.cjs');

const root = path.resolve(__dirname, '..');
const artifacts = path.join(root, 'build', 'native-tests', `crypto-fixtures-${process.pid}`);
let executable;

before(() => {
  fs.mkdirSync(artifacts, { recursive: true });
  executable = compileDriver();
});

function run(arguments_, timeout = 30_000) {
  const result = spawnSync(executable, arguments_, {
    cwd: root, encoding: 'utf8', timeout, maxBuffer: 4 * 1024 * 1024, windowsHide: true,
  });
  assert.equal(result.error, undefined, String(result.error || ''));
  assert.equal(result.status, 0, `${arguments_[0]} failed\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function compareFixture(name, fixture) {
  const encrypted = path.join(artifacts, `${name}.encrypted.mp4`);
  const expected = path.join(artifacts, `${name}.expected.mp4`);
  fs.writeFileSync(encrypted, fixture.encrypted);
  fs.writeFileSync(expected, fixture.expected);
  assert.match(run(['compare', encrypted, expected]), /PASS sequential, 600 seeks/);
  return { ...fixture, encryptedPath: encrypted, expectedPath: expected };
}

function compare(name, options) {
  return compareFixture(name, makeFixture(options));
}

function locate(fixture, type, index = 0) {
  const entry = fixture.boxes.filter((candidate) => candidate.type === type)[index];
  assert.ok(entry, `fixture contains ${type}[${index}]`);
  return entry;
}

function reject(name, options, change) {
  const fixture = makeFixture(options);
  let damaged = Buffer.from(fixture.encrypted);
  damaged = change(damaged, fixture) || damaged;
  const input = path.join(artifacts, `${name}.invalid.mp4`);
  fs.writeFileSync(input, damaged);
  assert.match(run(['reject', input]), /^REJECT -\d+ /);
}

test('progressive CENC whole samples with 8-byte IVs match independent plaintext', () => {
  compare('basic-iv8', {});
});

test('16-byte IV hvc1 samples preserve full-counter carry and co64 offsets', () => {
  compare('hvc1-iv16', { tracks: [{
    codec: 'hvc1', ivSize: 16, co64: true, tencVersion: 1,
    samples: [{ size: 129, iv: Buffer.alloc(16, 0xff) }, { size: 63 }],
  }] });
});

test('encrypted AAC audio entries with both supported audio header versions', () => {
  compare('audio-v0-v1', { tracks: [
    { kind: 'audio', ivSize: 8, samples: [41, 67, 101] },
    { kind: 'audio', audioVersion: 1, ivSize: 16, samples: [23, 31, 47], auxiliaryType: true },
  ] });
});

test('subsample CTR continuity survives clear gaps, whole, full-clear, and zero-size samples', () => {
  compare('subsamples', { tracks: [{
    ivSize: 16, chunks: [2, 1, 2], auxiliaryVariable: true,
    samples: [
      { size: 73, subsamples: [[5, 17], [7, 44]] },
      { size: 41, subsamples: [[41, 0]] },
      { size: 0, subsamples: [[0, 0]] },
      { size: 97 },
      { size: 33, subsamples: [[0, 1], [2, 0], [0, 15], [3, 12]] },
    ],
  }] });
});

test('samples larger than 64 KB decrypt through bounded short network reads', () => {
  compare('large-samples', { tracks: [{
    samples: [
      { size: 81937, subsamples: [[17, 65537], [11, 16372]] },
      { size: 131109 },
    ],
  }] });
});

test('fixed stsz sizes and changing samples-per-chunk mappings stay in sync', () => {
  compare('fixed-stsz', { tracks: [{
    fixedSize: true, chunks: [3, 1, 2], samples: [64, 64, 64, 64, 64, 64], auxiliaryVariable: true,
  }] });
});

test('tail moov uses absolute 64-bit auxiliary offsets without fetching mdat on open', () => {
  compare('tail-moov', { tailMoov: true, tracks: [{
    co64: true, ivSize: 16, auxiliaryType: true, auxiliaryOffset64: true,
    samples: [211, 127, 91],
  }] });
});

test('extended-size containers, sample entries, and metadata tables preserve offsets', () => {
  compare('extended-boxes', { extended: true, tailMoov: true, tracks: [
    { co64: true, ivSize: 8, samples: [91, 53] },
    { kind: 'audio', ivSize: 16, auxiliaryOffset64: true, samples: [47, 111] },
  ] });
});

test('multiple mdats and interleaved tracks permit nonmonotonic chunk storage', () => {
  compare('multiple-mdats', { mdatCount: 2, tracks: [
    { co64: true, ivSize: 8, samples: [37, 53, 79, 113] },
    { kind: 'audio', ivSize: 16, chunks: [2, 1, 1], samples: [41, 67, 29, 31] },
    { kind: 'audio', encrypted: false, samples: [23, 71, 19] },
  ] });
});

test('inline senc without optional saiz/saio also produces clear output', () => {
  compare('senc-only', { tracks: [{ auxiliary: false, samples: [83, 149] }] });
});

test('top-level and moov PSSH version 0/1 become free with all other bytes preserved', () => {
  compare('pssh', { pssh: true, tailMoov: true, extended: true, tracks: [{
    samples: [{ size: 73, subsamples: [[5, 17], [7, 44]] }, { size: 97 }],
  }] });
});

test('entirely clear audio/video tracks pass through byte for byte', () => {
  const fixture = makeFixture({ tracks: [
    { encrypted: false, samples: [37, 59, 101] },
    { kind: 'audio', encrypted: false, co64: true, samples: [41, 67] },
  ] });
  assert.deepEqual(fixture.encrypted, fixture.expected);
  compareFixture('clear-passthrough', fixture);
});

test('protected tracks containing only clear or empty samples retain their plaintext', () => {
  compare('full-clear-protected', { tracks: [{
    samples: [{ size: 41, subsamples: [[41, 0]] }, { size: 0, subsamples: [] },
      { size: 79, subsamples: [[37, 0], [42, 0]] }],
  }] });
});

test('empty tracks with zero sample/chunk/encryption counts are safe', () => {
  compare('empty-tracks', { tracks: [{ samples: [] }, { encrypted: false, samples: [] }] });
});

test('an EOF-sized mdat uses the remainder of the file without altering media bytes', () => {
  const fixture = makeFixture();
  const last = fixture.boxes.filter((entry) => entry.parent === null).at(-1);
  for (const data of [fixture.encrypted, fixture.expected]) {
    data.writeUInt32BE(0, last.start);
    data.write('mdat', last.start + 4, 4, 'latin1');
  }
  compareFixture('eof-mdat', fixture);
});

test('an EOF-sized tail moov remains length-preserving after header patches', () => {
  const fixture = makeFixture({ tailMoov: true });
  const movie = locate(fixture, 'moov');
  fixture.encrypted = fixture.encrypted.subarray(0, movie.end);
  fixture.expected = fixture.expected.subarray(0, movie.end);
  fixture.encrypted.writeUInt32BE(0, movie.start);
  fixture.expected.writeUInt32BE(0, movie.start);
  compareFixture('eof-moov', fixture);
});

const invalidCases = [
  ['child box exceeds its parent', {}, (data, fixture) => {
    data.writeUInt32BE(data.length, locate(fixture, 'stsz').start);
  }],
  ['extended box is shorter than its own header', { extended: true }, (data, fixture) => {
    data.writeBigUInt64BE(8n, locate(fixture, 'tenc').start + 8);
  }],
  ['sample count exceeds the allocation limit', {}, (data, fixture) => {
    data.writeUInt32BE(1000001, locate(fixture, 'stsz').payload + 8);
  }],
  ['inline senc is missing', {}, (data, fixture) => {
    data.write('free', locate(fixture, 'senc').start + 4, 4, 'latin1');
  }],
  ['original frma format is missing', {}, (data, fixture) => {
    data.write('free', locate(fixture, 'frma').start + 4, 4, 'latin1');
  }],
  ['legacy senc override flag is unsupported', {}, (data, fixture) => {
    data.writeUInt32BE(1, locate(fixture, 'senc').payload);
  }],
  ['invalid IV length is rejected', {}, (data, fixture) => {
    data[locate(fixture, 'tenc').payload + 7] = 12;
  }],
  ['CBCS encryption is unsupported', {}, (data, fixture) => {
    data.write('cbcs', locate(fixture, 'schm').payload + 4, 4, 'latin1');
  }],
  ['pattern encryption is unsupported', {}, (data, fixture) => {
    const start = locate(fixture, 'tenc').payload;
    data[start] = 1;
    data[start + 5] = 0x11;
  }],
  ['senc sample count differs from stsz', {}, (data, fixture) => {
    data.writeUInt32BE(4, locate(fixture, 'senc').payload + 4);
  }],
  ['subsamples omit bytes at the end of a sample', {
    tracks: [{ samples: [{ size: 73, subsamples: [[5, 17], [7, 44]] }] }],
  }, (data, fixture) => {
    data.writeUInt32BE(16, locate(fixture, 'senc').payload + 8 + 8 + 2 + 2);
  }],
  ['subsample lengths exceed the sample', {
    tracks: [{ samples: [{ size: 73, subsamples: [[5, 17], [7, 44]] }] }],
  }, (data, fixture) => {
    data.writeUInt32BE(0xffffffff, locate(fixture, 'senc').payload + 8 + 8 + 2 + 2);
  }],
  ['saiz entry size disagrees with senc', {}, (data, fixture) => {
    data[locate(fixture, 'saiz').payload + 4] = 9;
  }],
  ['saio does not point at the first inline IV', {}, (data, fixture) => {
    const start = locate(fixture, 'saio').payload + 8;
    data.writeUInt32BE(data.readUInt32BE(start) + 1, start);
  }],
  ['saiz and saio are not paired', {}, (data, fixture) => {
    data.write('free', locate(fixture, 'saio').start + 4, 4, 'latin1');
  }],
  ['encrypted sample points into ftyp outside every mdat', { tracks: [{ samples: [8] }] }, (data, fixture) => {
    data.writeUInt32BE(8, locate(fixture, 'stco').payload + 8);
  }],
  ['co64 offset overflows the file range', { tracks: [{ co64: true, samples: [8] }] }, (data, fixture) => {
    data.writeBigUInt64BE(0xfffffffffffffffen, locate(fixture, 'co64').payload + 8);
  }],
  ['clear and protected tracks alias the same sample data', { tracks: [
    { samples: [73] }, { kind: 'audio', encrypted: false, samples: [73] },
  ] }, (data, fixture) => {
    data.writeUInt32BE(fixture.tracks[0].samples[0].offset, locate(fixture, 'stco', 1).payload + 8);
  }],
  ['two encrypted sample ranges overlap', {}, (data, fixture) => {
    data.writeUInt32BE(fixture.tracks[0].samples[0].offset + 1, locate(fixture, 'stco').payload + 12);
  }],
  ['sample-to-chunk table starts at chunk zero', {}, (data, fixture) => {
    data.writeUInt32BE(0, locate(fixture, 'stsc').payload + 8);
  }],
  ['sample-to-chunk mapping expands past the sample count', {}, (data, fixture) => {
    data.writeUInt32BE(0xffffffff, locate(fixture, 'stsc').payload + 12);
  }],
  ['sample description index selects an unsupported description', {}, (data, fixture) => {
    data.writeUInt32BE(2, locate(fixture, 'stsc').payload + 16);
  }],
  ['encrypted entry uses an external data reference', {}, (data, fixture) => {
    data.writeUInt16BE(2, locate(fixture, 'encv').payload + 6);
  }],
  ['duplicate chunk tables are rejected', {}, (data, fixture) => {
    data.write('stco', locate(fixture, 'saio').start + 4, 4, 'latin1');
  }],
  ['PSSH version 1 key count exceeds the box', { pssh: true }, (data, fixture) => {
    const target = fixture.boxes.find((entry) => entry.type === 'pssh' &&
      entry.parent?.type === 'moov' && data[entry.payload] === 1);
    data.writeUInt32BE(0xffffffff, target.payload + 20);
  }],
  ['PSSH data length is inconsistent', { pssh: true }, (data, fixture) => {
    const target = fixture.boxes.find((entry) => entry.type === 'pssh' &&
      entry.parent?.type === 'moov' && data[entry.payload] === 0);
    data.writeUInt32BE(0xffffffff, target.payload + 20);
  }],
  ['fragmented MP4 top-level moof is unsupported', {}, (data) => Buffer.concat([data, box('moof')])],
  ['fragmented MP4 movie extends with mvex', {}, (data, fixture) => {
    data.write('mvex', locate(fixture, 'mvhd').start + 4, 4, 'latin1');
  }],
  ['top-level box is shorter than its header', {}, (data) => { data.writeUInt32BE(4, 0); }],
  ['top-level box is truncated', {}, (data) => data.subarray(0, data.length - 3)],
  ['moov is absent', {}, (data, fixture) => {
    data.write('free', locate(fixture, 'moov').start + 4, 4, 'latin1');
  }],
  ['mdat is absent', {}, (data, fixture) => {
    data.write('free', locate(fixture, 'mdat').start + 4, 4, 'latin1');
  }],
  ['multiple moov boxes are rejected', {}, (data, fixture) => {
    const movie = locate(fixture, 'moov');
    return Buffer.concat([data, data.subarray(movie.start, movie.end)]);
  }],
  ['multiple content key IDs are unsupported', { tracks: [
    { samples: [73] }, { kind: 'audio', samples: [73], kid: Buffer.from(KID).fill(0x42) },
  ] }, () => {}],
  ['encrypted original sample entry is not presented as clear', {}, (data, fixture) => {
    data.write('encv', locate(fixture, 'frma').payload, 4, 'latin1');
  }],
];

for (const [index, [name, options, change]] of invalidCases.entries()) {
  test(`rejects ${name}`, () => reject(`invalid-${index}`, options, change));
}

test('4000 deterministic malformed and truncated mutations preserve stream ownership and memory safety', () => {
  const fixture = makeFixture({ pssh: true, tracks: [{
    samples: [{ size: 73, subsamples: [[5, 17], [7, 44]] }, { size: 97 }],
  }] });
  const input = path.join(artifacts, 'mutation-input.mp4');
  fs.writeFileSync(input, fixture.encrypted);
  assert.match(run(['mutate', input], 120_000), /PASS 4000 deterministic malformed\/truncated mutations/);
});
