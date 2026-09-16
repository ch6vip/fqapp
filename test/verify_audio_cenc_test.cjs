'use strict';

// Offline regression fixtures exercise the actual diagnostic script. The media
// is encrypted independently by Node/OpenSSL, with no live URLs or credentials.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const { test } = require('node:test');
const { makeFixture } = require('./support/cenc_fixture.cjs');

const script = fs.readFileSync(path.join(__dirname, '../scripts/verify_audio_cenc.cjs'), 'utf8');

// Invert the published byte transform for a synthetic, known content key.
function spadeForKey(key) {
  const decoded = Buffer.from('x' + key.toString('hex'), 'ascii');
  const raw = Buffer.alloc(decoded.length + 1);
  let previousA = 0x55;
  let previousB = 0xf6;
  for (let i = 0; i < decoded.length; i++) {
    const bits = i.toString(2).split('1').length - 1;
    const current = ((decoded[i] + bits + 0x15) & 0xff) ^ (i & 1 ? previousA : previousB);
    const keep = i & 1 ? current : previousA;
    if (!(i & 1)) previousB = current;
    raw[i + 1] = current;
    previousA = keep;
  }
  raw[0] = raw[1] ^ raw[2] ^ 0x30;
  return raw.toString('base64');
}

function transport(options = {}) {
  const state = { calls: [], destroyed: false };
  state.get = (url, settings, callback) => {
    state.calls.push({ url, settings });
    const request = new EventEmitter();
    const response = new EventEmitter();
    response.statusCode = options.status ?? 200;
    response.headers = options.headers ?? {};
    response.complete = options.complete ?? true;
    request.destroy = response.destroy = () => { state.destroyed = true; };
    setImmediate(() => {
      callback(response);
      if (state.destroyed) return;
      for (const chunk of options.chunks ?? [Buffer.from('body')]) {
        response.emit('data', chunk);
        if (state.destroyed) return;
      }
      if (options.aborted) response.emit('aborted');
      else if (options.end !== false) response.emit('end');
    });
    return request;
  };
  return state;
}

function diagnostic(fixture, transportOptions = {}) {
  const network = transport({ chunks: fixture ? [fixture.encrypted] : undefined, ...transportOptions });
  const output = [];
  const processState = { argv: ['node', 'verify_audio_cenc.cjs', 'fixture.json'], env: {}, exitCode: 0,
    exit(code) { this.exitCode = code; throw new Error(`exit ${code}`); } };
  const payload = { video_info: { data: { video_model_datas: [{
    item_id: 'fixture', item_status: 0,
    video_model: JSON.stringify({ media_type: 'audio', video_duration: 1, video_list: [{
      main_url: 'https://example.invalid/fixture.m4a',
      encrypt_info: { encrypt: true, encryption_method: 'cenc-aes-ctr', spade_a: spadeForKey(fixture?.key ?? Buffer.alloc(16)) },
    }] }),
  }] } } };
  const context = vm.createContext({
    Buffer, URL, setTimeout, clearTimeout,
    console: { log: value => output.push(String(value)), error: value => output.push(String(value)) },
    process: processState, module: { exports: {} },
    require(name) {
      if (name === 'https' || name === 'node:https') return network;
      if (name === 'fs' || name === 'node:fs') return {
        readFileSync: () => JSON.stringify(payload),
        statSync: () => ({ size: JSON.stringify(payload).length }),
      };
      return require(name);
    },
  });
  // The original script invokes main unconditionally; suppress only that CLI
  // launcher so its functions can be exercised without an uncontrolled fetch.
  vm.runInContext(script.replace(/\nmain\(\)\.catch\([\s\S]*$/, ''), context);
  return { network, context, output, processState,
    run: expression => vm.runInContext(expression, context),
    async main() {
      try { await vm.runInContext('main()', context); }
      catch (error) { processState.exitCode = 1; output.push(`ERR ${error.message}`); }
      return { code: processState.exitCode, output: output.join('\n') };
    },
  };
}

function audioFixture(options = {}) {
  return makeFixture({ tracks: [{ kind: 'audio', samples: [
    { plain: Buffer.from([0x00, 0x11, 0x22]) },
    { plain: Buffer.from([0x20, 0x33, 0x44]) },
  ], ...options }] });
}

test('diagnostic derives the independent fixture key and checks all audio sample heads', async () => {
  const fixture = audioFixture();
  const d = diagnostic(fixture);
  d.context.spade = spadeForKey(fixture.key);
  assert.deepEqual(Buffer.from(d.run('spadeContentKey(spade)')), fixture.key);
  const result = await d.main();
  assert.equal(result.code, 0, result.output);
  assert.match(result.output, /2 ok \/ 0 bad/);
  assert.match(result.output, /RESULT: PASS/);
  assert.match(result.output, /heuristic/);
});

for (const [name, options, track] of [
  ['16-byte IV', {}, { ivSize: 16 }],
  ['version 1 tenc', {}, { tencVersion: 1 }],
  ['version 1 audio entry', {}, { audioVersion: 1 }],
  ['fixed sample sizes', {}, { fixedSize: true }],
  ['64-bit chunk offsets', {}, { co64: true }],
  ['multiple samples per chunk', {}, { chunks: [2] }],
  ['senc without auxiliary tables', {}, { auxiliary: false }],
  ['variable auxiliary sizes', {}, { auxiliaryVariable: true }],
  ['typed auxiliary tables', {}, { auxiliaryType: true }],
  ['64-bit auxiliary offsets', {}, { auxiliaryOffset64: true }],
  ['extended box headers', { extended: true }, {}],
  ['tail metadata', { tailMoov: true }, {}],
  ['multiple media-data boxes', { mdatCount: 2 }, {}],
]) {
  test('valid audio metadata: ' + name, async () => {
    const fixture = makeFixture({ ...options, tracks: [{ kind: 'audio', samples: [
      { plain: Buffer.from([0, 17, 34]) }, { plain: Buffer.from([32, 51, 68]) },
    ], ...track }] });
    const result = await diagnostic(fixture).main();
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /2 ok \/ 0 bad/);
  });
}

test('AAC metadata is selected from its own track when a video track comes first', async () => {
  const fixture = makeFixture({ tracks: [{ kind: 'video' }, {
    kind: 'audio', samples: [{ plain: Buffer.from([0, 17, 34]) }],
  }] });
  const result = await diagnostic(fixture).main();
  assert.equal(result.code, 0, result.output);
  assert.match(result.output, /1 ok \/ 0 bad/);
});

test('failed AAC head checks have a failing command exit status', async () => {
  const d = diagnostic(audioFixture({ samples: [{ plain: Buffer.from([0xe0, 0x11, 0x22]) }] }));
  const result = await d.main();
  assert.match(result.output, /RESULT: FAIL/);
  assert.notEqual(result.code, 0, result.output);
});

test('an omitted IV cannot make a failing second sample disappear from verification', async () => {
  const fixture = audioFixture({ samples: [
    { plain: Buffer.from([0x00, 0x11, 0x22]) },
    { plain: Buffer.from([0xe0, 0x33, 0x44]) },
  ] });
  const senc = fixture.boxes.find(box => box.type === 'senc');
  fixture.encrypted.writeUInt32BE(1, senc.payload + 4);
  const result = await diagnostic(fixture).main();
  assert.notEqual(result.code, 0, result.output);
  assert.doesNotMatch(result.output, /RESULT: PASS/);
});

for (const [name, mutate] of [
  ['invalid IV size', f => { f.encrypted[f.boxes.find(b => b.type === 'tenc').payload + 7] = 7; }],
  ['unsupported senc flags', f => { f.encrypted[f.boxes.find(b => b.type === 'senc').payload + 3] = 1; }],
  ['non-CENC scheme', f => { f.encrypted.write('cbcs', f.boxes.find(b => b.type === 'schm').payload + 4); }],
  ['chunk table omits samples', f => { f.encrypted.writeUInt32BE(1, f.boxes.find(b => b.type === 'stco').payload + 4); }],
  ['sample is outside media data', f => { f.encrypted.writeUInt32BE(0, f.boxes.find(b => b.type === 'stco').payload + 8); }],
  ['external data reference', f => { f.encrypted[f.boxes.find(b => b.type === 'url ').payload + 3] = 0; }],
  ['overlapping chunks', f => {
    const p = f.boxes.find(b => b.type === 'stco').payload;
    f.encrypted.writeUInt32BE(f.encrypted.readUInt32BE(p + 8), p + 12);
  }],
  ['unsupported sample description', f => { f.encrypted.writeUInt32BE(2, f.boxes.find(b => b.type === 'stsc').payload + 16); }],
  ['inconsistent auxiliary sample count', f => { f.encrypted.writeUInt32BE(1, f.boxes.find(b => b.type === 'saiz').payload + 5); }],
  ['inconsistent auxiliary record size', f => { f.encrypted[f.boxes.find(b => b.type === 'saiz').payload + 4] = 9; }],
  ['inconsistent auxiliary offset', f => { f.encrypted.writeUInt32BE(1, f.boxes.find(b => b.type === 'saio').payload + 8); }],
  ['sample encryption group override', f => {
    const b = f.boxes.find(b => b.type === 'stts');
    f.encrypted.write('sbgp', b.start + 4);
    f.encrypted.write('seig', b.payload + 4);
  }],
  ['PIFF encryption UUID', f => {
    const b = f.boxes.find(b => b.type === 'stts');
    f.encrypted.write('uuid', b.start + 4);
    Buffer.from('a2394f525a9b4f14a2446c427c648df4', 'hex').copy(f.encrypted, b.payload);
  }],
  ['truncated extended box header', f => { f.encrypted = Buffer.from([0, 0, 0, 1, 109, 111, 111, 118]); }],
]) {
  test(`diagnostic rejects ${name}`, async () => {
    const fixture = audioFixture();
    mutate(fixture);
    const result = await diagnostic(fixture).main();
    assert.notEqual(result.code, 0, result.output);
    assert.doesNotMatch(result.output, /RESULT: PASS/);
  });
}

test('subsample clear bytes are preserved by the AAC head check', async () => {
  const fixture = audioFixture({ samples: [{
    plain: Buffer.from([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
    subsamples: [[3, 2], [1, 2]],
  }] });
  const result = await diagnostic(fixture).main();
  assert.equal(result.code, 0, result.output);
  assert.match(result.output, /RESULT: PASS/);
  assert.match(result.output, /first heads  : 0011223344556677/);
});

test('malformed spade keys fail before fetching any media', async () => {
  const d = diagnostic();
  for (const value of ['', 'AA==', 'not-base64!']) {
    d.context.badSpade = value;
    assert.throws(() => d.run('spadeContentKey(badSpade)'));
  }
  assert.equal(d.network.calls.length, 0);
});

test('HTTPS download verifies the server certificate', async () => {
  const d = diagnostic();
  const data = await d.run('fetchBuffer("https://example.invalid/audio")');
  assert.equal(data.toString(), 'body');
  assert.notEqual(d.network.calls[0].settings.rejectUnauthorized, false);
});

for (const [name, options, expression, message] of [
  ['HTTP error response', { status: 503 }, 'fetchBuffer("https://example.invalid/audio")', /HTTP.*503/],
  ['redirect response', { status: 302 }, 'fetchBuffer("https://example.invalid/audio")', /HTTP.*302/],
  ['oversized Content-Length', { headers: { 'content-length': '10' } }, 'fetchBuffer("https://example.invalid/audio", {maxBytes: 8})', /limit|large/i],
  ['oversized chunked response', { chunks: [Buffer.alloc(5), Buffer.alloc(5)] }, 'fetchBuffer("https://example.invalid/audio", {maxBytes: 8})', /limit|large/i],
  ['truncated body', { headers: { 'content-length': '10' } }, 'fetchBuffer("https://example.invalid/audio")', /length|truncat|incomplete/i],
  ['aborted response', { aborted: true }, 'fetchBuffer("https://example.invalid/audio", {timeoutMs: 100})', /abort|incomplete/i],
  ['stalled response', { end: false }, 'fetchBuffer("https://example.invalid/audio", {timeoutMs: 30})', /timed out|timeout/i],
]) {
  test(`HTTPS download rejects and releases an ${name}`, { timeout: 500 }, async () => {
    const d = diagnostic(undefined, options);
    await assert.rejects(d.run(expression), message);
    assert.equal(d.network.destroyed, true);
  });
}
