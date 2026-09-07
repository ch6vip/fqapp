'use strict';

const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..', '..');
let compiledDriver;

function nativeCompiler() {
  const command = process.env.NATIVE_CC || process.env.CC || 'cc';
  const prefix = /(?:^|[\\/])zig(?:\.exe)?$/i.test(command) ? ['cc'] : [];
  const flags = (process.env.NATIVE_CFLAGS || '').split(/\s+/).filter(Boolean);
  return { command, prefix, flags };
}

function compileDriver() {
  if (compiledDriver) return compiledDriver;
  const directory = path.join(root, 'build', 'native-tests');
  mkdirSync(directory, { recursive: true });
  const output = path.join(directory,
    `stream-driver-${process.pid}${process.platform === 'win32' ? '.exe' : ''}`);
  const { command, prefix, flags } = nativeCompiler();
  const sources = [
    'native/tests/stream_driver.c',
    'native/crypto_core/sp_error.c',
    'native/crypto_core/sp_stream.c',
    'native/crypto_core/mp4_cenc.c',
    'native/crypto_core/sp_aes.c',
    'native/third_party/tiny_aes/aes.c',
  ];
  const result = spawnSync(command, [
    ...prefix, '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
    '-DCBC=0', '-DCTR=0', '-DECB=1',
    '-I', path.join(root, 'native', 'crypto_core'),
    ...flags, ...sources.map((source) => path.join(root, source)), '-o', output,
  ], { cwd: root, encoding: 'utf8', timeout: 240_000, windowsHide: true });
  assert.equal(result.error, undefined,
    `Set NATIVE_CC to a host C compiler executable (cc, clang, gcc, or zig). ${result.error || ''}`);
  assert.equal(result.status, 0, result.stderr || result.stdout);
  compiledDriver = output;
  return compiledDriver;
}

module.exports = { compileDriver, nativeCompiler };
