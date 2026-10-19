#!/usr/bin/env node
'use strict';

// Checks ELF layout only. APK ZIP alignment and runtime/device checks are separate.
const fs = require('node:fs');

// Inspects one ELF shared library (32-bit ARM or 64-bit ARM64) and returns
// the p_align values of its LOAD segments. Both ELF classes share the same
// 16 KiB rule: every LOAD segment p_align >= 16 KiB, power-of-two, with
// file offset and virtual address congruent mod 16 KiB.
function inspectElf(bytes) {
  if (bytes.length < 64 || bytes.subarray(0, 4).toString('hex') !== '7f454c46' ||
      bytes[5] !== 1 || bytes[6] !== 1 ||
      bytes.readUInt16LE(16) !== 3) {
    throw new Error('Expected an ELF little-endian shared library');
  }
  const elfClass = bytes[4];
  if (elfClass !== 1 && elfClass !== 2) {
    throw new Error(`Expected ELF class 1 (32-bit) or 2 (64-bit), got ${elfClass}`);
  }
  const is64 = elfClass === 2;
  const machine = bytes.readUInt16LE(18);
  const expectedMachine = is64 ? 183 : 40;
  const expectedLabel = is64 ? 'ELF64 little-endian ARM64' : 'ELF32 little-endian ARM';
  if (machine !== expectedMachine) {
    throw new Error(`Expected a ${expectedLabel} shared library (e_machine ${machine})`);
  }
  // ELF64: e_phoff u64@32, e_phentsize u16@54, e_phnum u16@56, entry 56 bytes.
  // ELF32: e_phoff u32@28, e_phentsize u16@42, e_phnum u16@44, entry 32 bytes.
  // LOAD fields, 64-bit: p_type u32@0, p_offset u64@8, p_vaddr u64@16,
  //   p_filesz u64@32, p_memsz u64@40, p_align u64@48.
  // LOAD fields, 32-bit: p_type u32@0, p_offset u32@4, p_vaddr u32@8,
  //   p_filesz u32@16, p_memsz u32@20, p_align u32@28.
  const offset = is64 ? bytes.readBigUInt64LE(32) : BigInt(bytes.readUInt32LE(28));
  const entrySize = bytes.readUInt16LE(is64 ? 54 : 42);
  const entryCount = bytes.readUInt16LE(is64 ? 56 : 44);
  const minEntrySize = is64 ? 56 : 32;
  if (entrySize < minEntrySize || entryCount === 0 || entryCount === 0xffff ||
      offset + BigInt(entrySize) * BigInt(entryCount) > BigInt(bytes.length)) {
    throw new Error('Invalid or unsupported ELF program header table');
  }
  const readField = (at, fieldOffset, size) =>
    size === 8 ? bytes.readBigUInt64LE(at + fieldOffset) : BigInt(bytes.readUInt32LE(at + fieldOffset));
  const alignments = [];
  for (let i = 0; i < entryCount; ++i) {
    const at = Number(offset) + i * entrySize;
    if (bytes.readUInt32LE(at) !== 1) continue;
    const fieldSize = is64 ? 8 : 4;
    const field = (fieldOffset) => readField(at, fieldOffset, fieldSize);
    const fileOffset = field(is64 ? 8 : 4);
    const address = field(is64 ? 16 : 8);
    const fileSize = field(is64 ? 32 : 16);
    const memorySize = field(is64 ? 40 : 20);
    const alignment = field(is64 ? 48 : 28);
    const addressSpace = is64 ? (1n << 64n) : (1n << 32n);
    if (fileOffset + fileSize > BigInt(bytes.length) || memorySize < fileSize ||
        address + memorySize > addressSpace) {
      throw new Error(`LOAD ${i} has invalid file or memory bounds`);
    }
    if (alignment < 16384n || (alignment & (alignment - 1n)) !== 0n ||
        fileOffset % 16384n !== address % 16384n) {
      throw new Error(`LOAD ${i} is not 16 KiB aligned (p_align=0x${alignment.toString(16)}, ` +
        `offset=0x${fileOffset.toString(16)}, address=0x${address.toString(16)})`);
    }
    alignments.push(`0x${alignment.toString(16)}`);
  }
  if (alignments.length === 0) throw new Error('ELF has no LOAD segments');
  return alignments;
}

if (require.main === module) {
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error('Usage: node scripts/check_native_alignment.cjs library.so [other.so ...]');
    process.exitCode = 1;
  }
  for (const file of files) {
    try {
      const alignments = inspectElf(fs.readFileSync(file));
      console.log(`${file}: ${alignments.length} LOAD segments, ${[...new Set(alignments)].join(', ')}; 16 KiB ELF layout OK`);
    } catch (error) {
      console.error(`${file}: ${error.message}`);
      process.exitCode = 1;
    }
  }
}

module.exports = { inspectElf, inspectArm64Elf: inspectElf };
