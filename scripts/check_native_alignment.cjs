#!/usr/bin/env node
'use strict';

// Checks ELF layout only. APK ZIP alignment and runtime/device checks are separate.
const fs = require('node:fs');

function inspectArm64Elf(bytes) {
  if (bytes.length < 64 || bytes.subarray(0, 4).toString('hex') !== '7f454c46' ||
      bytes[4] !== 2 || bytes[5] !== 1 || bytes[6] !== 1 ||
      bytes.readUInt16LE(16) !== 3 || bytes.readUInt16LE(18) !== 183) {
    throw new Error('Expected an ELF64 little-endian ARM64 shared library');
  }
  const offset = bytes.readBigUInt64LE(32);
  const entrySize = bytes.readUInt16LE(54);
  const entryCount = bytes.readUInt16LE(56);
  if (entrySize < 56 || entryCount === 0 || entryCount === 0xffff ||
      offset + BigInt(entrySize) * BigInt(entryCount) > BigInt(bytes.length)) {
    throw new Error('Invalid or unsupported ELF program header table');
  }
  const alignments = [];
  for (let i = 0; i < entryCount; ++i) {
    const at = Number(offset) + i * entrySize;
    if (bytes.readUInt32LE(at) !== 1) continue;
    const fileOffset = bytes.readBigUInt64LE(at + 8);
    const address = bytes.readBigUInt64LE(at + 16);
    const fileSize = bytes.readBigUInt64LE(at + 32);
    const memorySize = bytes.readBigUInt64LE(at + 40);
    const alignment = bytes.readBigUInt64LE(at + 48);
    if (fileOffset + fileSize > BigInt(bytes.length) || memorySize < fileSize ||
        address + memorySize > (1n << 64n)) {
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
      const alignments = inspectArm64Elf(fs.readFileSync(file));
      console.log(`${file}: ${alignments.length} LOAD segments, ${[...new Set(alignments)].join(', ')}; 16 KiB ELF layout OK`);
    } catch (error) {
      console.error(`${file}: ${error.message}`);
      process.exitCode = 1;
    }
  }
}

module.exports = { inspectArm64Elf };
