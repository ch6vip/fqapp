// Real encoded audio/video complements the byte-level synthetic CENC fixtures.
// Requires a C compiler (NATIVE_CC or cc) and FFmpeg with libx264/AAC support.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { before, test } = require('node:test');
const { compileDriver } = require('./support/native_compile.cjs');

const root = path.resolve(__dirname, '..');
const output = path.join(root, 'build', 'validation', `native-media-${process.pid}`);
const key = '00112233445566778899aabbccddeeff';
const kid = '102132435465768798a9bacbdcedfe0f';
let driver;
const references = new Map();

function run(executable, args) {
  const result = spawnSync(executable, args, { encoding: 'utf8', timeout: 120000, maxBuffer: 8 * 1024 * 1024 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, `${executable} failed\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function ffmpeg(args) {
  return run(process.env.FFMPEG || 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-nostdin', ...args]);
}

function frameHashes(file) {
  return ffmpeg(['-i', file, '-map', '0:v:0', '-map', '0:a:0', '-f', 'framemd5', '-'])
    .split(/\r?\n/).filter(line => line && !line.startsWith('#'));
}

before(() => {
  fs.mkdirSync(output, { recursive: true });
  driver = compileDriver();
  for (const format of ['avc1', 'hvc1']) {
    const reference = path.join(output, `${format}-reference.mp4`);
    ffmpeg([
      '-y', '-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=12',
      '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=44100',
      '-t', '1.25', '-c:v', format === 'avc1' ? 'libx264' : 'libx265',
      '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-tag:v', format,
      ...(format === 'hvc1' ? ['-x265-params', 'pools=1:frame-threads=1:log-level=error'] : []),
      '-c:a', 'aac', '-b:a', '48k', reference,
    ]);
    const frames = frameHashes(reference);
    assert.ok(frames.length > 20, 'Reference must contain decoded video and audio frames');
    references.set(format, { file: reference, frames });
  }
});

for (const format of ['avc1', 'hvc1']) {
  for (const fastStart of [false, true]) {
    test(`FFmpeg CENC ${format}/AAC decodes identically with ${fastStart ? 'front' : 'tail'} moov`, { timeout: 180000 }, () => {
      const reference = references.get(format);
      const name = `${format}-${fastStart ? 'front' : 'tail'}`;
      const encrypted = path.join(output, `${name}-encrypted.mp4`);
      const clear = path.join(output, `${name}-decrypted.mp4`);
      ffmpeg([
        '-y', '-i', reference.file, '-map', '0', '-c', 'copy',
        '-encryption_scheme', 'cenc-aes-ctr', '-encryption_key', key, '-encryption_kid', kid,
        ...(fastStart ? ['-movflags', '+faststart'] : []), encrypted,
      ]);
      run(driver, ['decrypt', encrypted, clear]);
      assert.equal(fs.statSync(clear).size, fs.statSync(encrypted).size, 'Decryption must preserve MP4 offsets');
      assert.deepEqual(frameHashes(clear), reference.frames, 'Every decoded video/audio frame must match the known clear media');
      // Re-read the same real file with random seeks and short network reads.
      run(driver, ['compare', encrypted, clear]);
    });
  }
}
