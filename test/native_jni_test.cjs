'use strict';

// Executes the production JNI bridge and C core on a Linux JDK. Android/JVM
// HttpRangeClient tests cover the real HTTP transport separately. Do not reuse
// NATIVE_CFLAGS here: loading an ASan library into an ordinary JVM needs extra
// runtime setup. NATIVE_JNI_CFLAGS is available for deliberate JVM-compatible
// instrumentation; ASan/UBSan coverage also runs in the standalone core tests.
const assert = require('node:assert/strict');
const { existsSync, mkdirSync, realpathSync, writeFileSync } = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { before, test } = require('node:test');
const { makeFixture, KEY } = require('./support/cenc_fixture.cjs');

const root = path.resolve(__dirname, '..');
const output = path.join(root, 'build', 'native-tests', 'jni');
const library = path.join(output, 'libshortplay_crypto.so');
const classes = path.join(output, 'classes');
const fixturePath = path.join(output, 'encrypted.mp4');
const expectedPath = path.join(output, 'expected.mp4');
const supported = process.platform === 'linux';
const required = process.env.NATIVE_JNI_REQUIRED === '1';
const skip = !supported && !required ? 'Real JNI regression requires Linux and a JDK; CI runs it without skipping.' : false;
let java;
let mediaPosition;

function run(command, args, timeout = 60_000) {
  const result = spawnSync(command, args, {
    cwd: root, encoding: 'utf8', timeout, maxBuffer: 8 * 1024 * 1024, windowsHide: true,
  });
  assert.equal(result.error, undefined, `${command}: ${result.error || ''}`);
  assert.equal(result.signal, null, `${command} terminated by ${result.signal}:\n${result.stdout}\n${result.stderr}`);
  assert.equal(result.status, 0, `${command} failed:\n${result.stdout}\n${result.stderr}`);
  return result;
}

function executableOnPath(name) {
  for (const directory of (process.env.PATH || '').split(path.delimiter)) {
    const candidate = path.join(directory, name);
    if (existsSync(candidate)) return realpathSync(candidate);
  }
  throw new Error(`Cannot find ${name}; install a JDK or set JAVA_HOME.`);
}

before(() => {
  if (!supported && !required) return;
  assert.equal(process.platform, 'linux', 'NATIVE_JNI_REQUIRED=1 requires a Linux runner; this check cannot be skipped in CI.');
  const javaHome = process.env.JAVA_HOME
    ? path.resolve(process.env.JAVA_HOME)
    : path.dirname(path.dirname(executableOnPath('javac')));
  java = path.join(javaHome, 'bin', 'java');
  const javac = path.join(javaHome, 'bin', 'javac');
  assert.ok(existsSync(path.join(javaHome, 'include', 'jni.h')), `Missing JDK JNI headers in ${javaHome}`);
  assert.ok(existsSync(path.join(javaHome, 'include', 'linux', 'jni_md.h')), `Missing Linux JNI headers in ${javaHome}`);
  mkdirSync(classes, { recursive: true });
  const compiler = process.env.NATIVE_CC || process.env.CC || 'cc';
  const compilerArgs = /(?:^|[\\/])zig(?:\.exe)?$/i.test(compiler) ? ['cc'] : [];
  compilerArgs.push('-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
    '-shared', '-fPIC', '-fvisibility=hidden', '-pthread', '-DCBC=0', '-DCTR=0', '-DECB=1',
    ...(process.env.NATIVE_JNI_CFLAGS || '').split(/\s+/).filter(Boolean),
    `-I${path.join(javaHome, 'include')}`, `-I${path.join(javaHome, 'include', 'linux')}`,
    `-I${path.join(root, 'native', 'crypto_core')}`,
    ...['android/jni_bridge.c', 'crypto_core/sp_error.c', 'crypto_core/sp_stream.c',
      'crypto_core/mp4_cenc.c', 'crypto_core/sp_aes.c', 'third_party/tiny_aes/aes.c']
      .map((file) => path.join(root, 'native', file)),
    '-Wl,--no-undefined', '-o', library);
  run(compiler, compilerArgs, 180_000);
  run(javac, ['--release', '17', '-Xlint:all', '-Werror', '-d', classes,
    path.join(root, 'native', 'tests', 'java', 'com', 'example', 'shortplay', 'CryptoNative.java')]);
  const fixture = makeFixture({
    tailMoov: true, extended: true, pssh: true, mdatCount: 2,
    tracks: [
      { kind: 'video', ivSize: 8, samples: [
        { size: 160123, subsamples: [[5, 70000], [23, 90095]] },
        { size: 41, subsamples: [[41, 0]] }, { size: 97 },
      ] },
      { kind: 'audio', ivSize: 16, samples: [{ size: 8193 }, { size: 31 }] },
      { kind: 'audio', encrypted: false, samples: [{ size: 79 }] },
    ],
  });
  writeFileSync(fixturePath, fixture.encrypted);
  writeFileSync(expectedPath, fixture.expected);
  mediaPosition = fixture.tracks[0].samples[0].offset;
}, { timeout: 240_000 });

for (const [scenario, description] of [
  ['abi', 'real JNI ABI opens, reads bounded plaintext, seeks randomly, and reports EOF'],
  ['errors', 'real JNI rejects malformed keys, invalid handles, and invalid buffer/seek bounds'],
  ['prewarm', 'real JNI init/prewarm and failed opens release their bridge requests'],
  ['callbacks', 'real JNI converts Java callback exceptions to IOException and permits a clean retry'],
  ['parallel', 'real JNI keeps concurrent handles and their plaintext positions independent'],
  ['cancel_connect', 'real JNI close cancels blocked connect and releases queued handle operations'],
  ['cancel_read', 'real JNI close cancels blocked read while unrelated handles remain usable'],
  ['close_races', 'real JNI read/seek/close races terminate without stale handles or leaked requests'],
]) {
  test(description, { skip, timeout: 90_000 }, () => {
    assert.equal(process.platform, 'linux');
    const result = run(java, ['-Xcheck:jni', '-ea', '-cp', classes,
      'com.example.shortplay.CryptoNative', scenario, library,
      fixturePath, expectedPath, KEY.toString('hex'), String(mediaPosition)]);
    assert.match(result.stdout, new RegExp(`JNI TEST OK: ${scenario}(?:\\r?\\n|$)`));
    assert.doesNotMatch(result.stdout + result.stderr,
      /WARNING in native method|FATAL ERROR in native method|JNI WARNING|runtime error:|AddressSanitizer/,
      'JVM JNI validation or sanitizer reported an error');
  });
}
