// Unit tests for scripts/check_native_alignment.cjs.
//
// The checker must accept 16 KiB-aligned ELF32 (ARM) and ELF64 (ARM64)
// libraries and reject misaligned ones, wrong-machine binaries, and
// non-ELF input. Fixtures are minimal hand-built ELFs: one LOAD segment
// with p_align 16 KiB, offset/address congruent mod 16 KiB.
//
// Run with: node --test test/check_native_alignment_test.cjs

'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { inspectElf, inspectArm64Elf } = require('../scripts/check_native_alignment.cjs');

function buildElf64({ machine = 183, align = 16384, offset = 0x4000, address = 0x4000 } = {}) {
  const total = 0x4000 + 0x100;
  const bytes = Buffer.alloc(total);
  bytes[0] = 0x7f; bytes[1] = 0x45; bytes[2] = 0x4c; bytes[3] = 0x46;
  bytes[4] = 2; bytes[5] = 1; bytes[6] = 1;
  bytes.writeUInt16LE(3, 16);
  bytes.writeUInt16LE(machine, 18);
  bytes.writeBigUInt64LE(64n, 32);
  bytes.writeUInt16LE(56, 54);
  bytes.writeUInt16LE(1, 56);
  const ph = 64;
  bytes.writeUInt32LE(1, ph);
  bytes.writeBigUInt64LE(BigInt(offset), ph + 8);
  bytes.writeBigUInt64LE(BigInt(address), ph + 16);
  bytes.writeBigUInt64LE(0x100n, ph + 32);
  bytes.writeBigUInt64LE(0x100n, ph + 40);
  bytes.writeBigUInt64LE(BigInt(align), ph + 48);
  return bytes;
}

function buildElf32({ machine = 40, align = 16384, offset = 0x4000, address = 0x4000 } = {}) {
  const total = 0x4000 + 0x100;
  const bytes = Buffer.alloc(total);
  bytes[0] = 0x7f; bytes[1] = 0x45; bytes[2] = 0x4c; bytes[3] = 0x46;
  bytes[4] = 1; bytes[5] = 1; bytes[6] = 1;
  bytes.writeUInt16LE(3, 16);
  bytes.writeUInt16LE(machine, 18);
  bytes.writeUInt32LE(52, 28);
  bytes.writeUInt16LE(32, 42);
  bytes.writeUInt16LE(1, 44);
  const ph = 52;
  bytes.writeUInt32LE(1, ph);
  bytes.writeUInt32LE(offset, ph + 4);
  bytes.writeUInt32LE(address, ph + 8);
  bytes.writeUInt32LE(0x100, ph + 16);
  bytes.writeUInt32LE(0x100, ph + 20);
  bytes.writeUInt32LE(align, ph + 28);
  return bytes;
}

test('accepts a 16 KiB-aligned ELF64 ARM64 library', () => {
  assert.deepEqual(inspectElf(buildElf64()), ['0x4000']);
});

test('accepts a 16 KiB-aligned ELF32 ARM library', () => {
  assert.deepEqual(inspectElf(buildElf32()), ['0x4000']);
});

test('rejects a 4 KiB-aligned LOAD segment in both ELF classes', () => {
  assert.throws(() => inspectElf(buildElf64({ align: 4096 })), /not 16 KiB aligned/);
  assert.throws(() => inspectElf(buildElf32({ align: 4096 })), /not 16 KiB aligned/);
});

test('rejects offset/address incongruence mod 16 KiB in ELF32', () => {
  assert.throws(
    () => inspectElf(buildElf32({ offset: 0x4000, address: 0x4001 })),
    /not 16 KiB aligned/,
  );
});

test('rejects a wrong-machine ELF for its class', () => {
  // An ELF32 header claiming AArch64, and an ELF64 header claiming ARM.
  assert.throws(() => inspectElf(buildElf32({ machine: 183 })), /ELF32 little-endian ARM/);
  assert.throws(() => inspectElf(buildElf64({ machine: 40 })), /ELF64 little-endian ARM64/);
});

test('rejects non-ELF input', () => {
  assert.throws(() => inspectElf(Buffer.from('not an elf at all, just text........')), /Expected an ELF/);
});

test('the legacy inspectArm64Elf export still works', () => {
  assert.equal(inspectArm64Elf, inspectElf);
});
