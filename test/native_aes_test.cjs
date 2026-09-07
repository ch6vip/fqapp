'use strict';

// Run with a native C compiler, for example:
//   NATIVE_CC=/path/to/zig node --test test/native_aes_test.cjs
// The executable path alone is used; `zig cc` is selected automatically.
const assert = require('node:assert/strict');
const { createCipheriv, createHash } = require('node:crypto');
const { mkdirSync } = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { before, test } = require('node:test');

const root = path.resolve(__dirname, '..');
const outputDirectory = path.join(root, 'build', 'native-tests');
const executable = path.join(outputDirectory,
  process.platform === 'win32' ? 'aes-vectors.exe' : 'aes-vectors');
const compiler = process.env.NATIVE_CC || process.env.CC || 'cc';

before(() => {
  mkdirSync(outputDirectory, { recursive: true });
  const arguments_ = /(?:^|[\\/])zig(?:\.exe)?$/i.test(compiler) ? ['cc'] : [];
  arguments_.push('-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
    '-DCBC=0', '-DCTR=0', '-DECB=1',
    ...(process.env.NATIVE_CFLAGS || '').split(/\s+/).filter(Boolean),
    path.join(root, 'native', 'tests', 'aes_vectors.c'),
    path.join(root, 'native', 'crypto_core', 'sp_aes.c'),
    path.join(root, 'native', 'third_party', 'tiny_aes', 'aes.c'),
    '-o', executable);
  const compiled = spawnSync(compiler, arguments_, {
    cwd: root,
    encoding: 'utf8',
    timeout: 180_000,
    windowsHide: true,
  });
  assert.equal(compiled.error, undefined,
    `Set NATIVE_CC to the path of a host C compiler (cc, clang, gcc, or zig). ${compiled.error || ''}`);
  assert.equal(compiled.status, 0, compiled.stderr || compiled.stdout);
});

function nativeResults(vectors) {
  const input = vectors.map(({ key, iv, offset, data }) =>
    `${key.toString('hex')} ${iv.toString('hex')} ${offset.toString(16)} ${data.length ? data.toString('hex') : '-'}`
  ).join('\n');
  const result = spawnSync(executable, [], {
    cwd: root,
    input: input.length ? `${input}\n` : '',
    encoding: 'utf8',
    timeout: 30_000,
    maxBuffer: 8 * 1024 * 1024,
    windowsHide: true,
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stderr);
  const lines = result.stdout.trim().split(/\r?\n/);
  assert.equal(lines.shift(), 'SELFTEST OK');
  assert.equal(lines.length, vectors.length);
  return lines.map((line) => Buffer.from(line === '-' ? '' : line, 'hex'));
}

// Node/OpenSSL provides the AES primitive and CTR implementation independently
// of tiny-AES-c. BigInt counter arithmetic lets the oracle check very large
// offsets without reading or allocating their preceding bytes.
function oracle({ key, iv, offset, data }) {
  const initial = Buffer.alloc(16);
  iv.copy(initial);
  const counter = (BigInt(`0x${initial.toString('hex')}`) + offset / 16n) % (1n << 128n);
  const adjustedIv = Buffer.from(counter.toString(16).padStart(32, '0'), 'hex');
  const skip = Number(offset % 16n);
  const cipher = createCipheriv('aes-128-ctr', key, adjustedIv);
  const padded = Buffer.concat([Buffer.alloc(skip), data]);
  return Buffer.concat([cipher.update(padded), cipher.final()]).subarray(skip);
}

function material(label, length) {
  return createHash('sha256').update(label).digest().subarray(0, length);
}

function payload(length, salt) {
  return Buffer.from(Array.from({ length }, (_, index) =>
    (index * 29 + salt * 17 + (index >>> 8)) & 255));
}

function checkVectors(vectors) {
  const actual = nativeResults(vectors);
  for (let index = 0; index < vectors.length; ++index) {
    assert.deepEqual(actual[index], oracle(vectors[index]),
      `CTR vector ${index}: IV=${vectors[index].iv.toString('hex')} offset=${vectors[index].offset} length=${vectors[index].data.length}`);
  }
}

test('NIST SP 800-38A AES-128 CTR vector, unaligned range, immutable context, and key wipe', () => {
  nativeResults([]);
});

test('CENC 8-byte IV reads match Node crypto at all block positions and boundary lengths', () => {
  const vectors = [];
  for (let offset = 0; offset < 64; ++offset) {
    for (const length of [0, 1, 15, 16, 17, 31, 32, 33, 257]) {
      vectors.push({
        key: material(`eight-byte-key-${offset}`, 16),
        iv: material(`eight-byte-iv-${offset}`, 8),
        offset: BigInt(offset),
        data: payload(length, offset + length),
      });
    }
  }
  checkVectors(vectors);
});

test('16-byte IV carry and complete 128-bit counter wrap match Node crypto', () => {
  const vectors = [];
  const offsets = [0n, 1n, 15n, 16n, 17n, 255n, 256n, 65535n,
    (1n << 32n) - 1n, 1n << 32n, (1n << 60n) + 19n, (1n << 64n) - 1n];
  const ivs = [
    '00000000000000000000000000000000',
    '000000000000000000000000000000ff',
    '0000000000000000ffffffffffffffff',
    'ffffffffffffffffffffffffffffffff',
    'fffffffffffffffffffffffffffffffc',
    '102030405060708090a0b0c0d0e0f0ff',
  ];
  for (const iv of ivs) {
    for (const offset of offsets) {
      vectors.push({
        key: material(`carry-key-${iv}`, 16),
        iv: Buffer.from(iv, 'hex'),
        offset,
        data: payload(97, vectors.length),
      });
    }
  }
  checkVectors(vectors);
});

test('large encrypted offsets with 8-byte IV and successive unrelated keys match Node crypto', () => {
  const vectors = [];
  const offsets = [1n << 20n, (1n << 32n) + 7n, (1n << 48n) - 1n,
    1n << 63n, (1n << 64n) - 1n];
  for (let index = 0; index < 25; ++index) {
    vectors.push({
      key: material(`independent-key-${index}`, 16),
      iv: material(`independent-iv-${index}`, 8),
      offset: offsets[index % offsets.length],
      data: payload(index % 2 ? 8192 : 4097, index),
    });
  }
  checkVectors(vectors);
});

test('arbitrary disjoint reads reproduce independently encrypted plaintext', () => {
  for (const ivLength of [8, 16]) {
    const key = material(`split-read-key-${ivLength}`, 16);
    const iv = material(`split-read-iv-${ivLength}`, ivLength);
    const plaintext = payload(8192, ivLength);
    const paddedIv = Buffer.alloc(16);
    iv.copy(paddedIv);
    const cipher = createCipheriv('aes-128-ctr', key, paddedIv);
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const ranges = [[8189, 3], [0, 17], [503, 259], [16, 1], [257, 4097],
      [4095, 17], [0, 8192], [15, 18], [8000, 0]];
    const vectors = ranges.map(([offset, length]) => ({
      key, iv, offset: BigInt(offset), data: ciphertext.subarray(offset, offset + length),
    }));
    const decrypted = nativeResults(vectors);
    ranges.forEach(([offset, length], index) => {
      assert.deepEqual(decrypted[index], plaintext.subarray(offset, offset + length));
    });
  }
});
