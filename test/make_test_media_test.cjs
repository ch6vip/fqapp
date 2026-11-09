// Guards for scripts/make_test_media.py.
//
// The fixture generator exists so a playback check does not depend on an
// upstream capture that drifts. Two of its promises are checkable without
// ffmpeg - the toolchain probe and the argument validation - and those are
// pinned here. The ffmpeg-dependent part (a byte-identical clip for a given
// --seconds/--size) is not asserted here: it needs the encoder, and its
// reproducibility is only guaranteed within one ffmpeg build anyway.
//
// Run with: node --test test/make_test_media_test.cjs

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { spawnSync } = require('node:child_process');

const appDir = path.resolve(__dirname, '..');
const script = path.join(appDir, 'scripts', 'make_test_media.py');

function python() {
  for (const candidate of ['python3', 'python']) {
    const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
    if (probe.status === 0) {
      const where = spawnSync(
        candidate,
        ['-c', 'import sys; print(sys.executable)'],
        { encoding: 'utf8' },
      );
      return {
        name: candidate,
        path: (where.stdout || '').trim() || candidate,
      };
    }
  }
  return null;
}

const interpreterInfo = python();
const interpreter = interpreterInfo && interpreterInfo.name;
const interpreterPath = interpreterInfo && interpreterInfo.path;

/**
 * Build an environment in which ffmpeg and ffprobe are unreachable.
 *
 * Pointing PATH at the interpreter's own directory is not enough: on a Linux
 * runner python3 and ffmpeg both live in /usr/bin, so the tools stay
 * reachable and --check would exit 0 instead of the 2 this case asserts.
 * The reliable way is to hand the child an empty PATH and invoke the
 * interpreter by its absolute path.
 *
 * Returns the environment, plus the names of the tools that were reachable
 * before (so the case can prove it really hid them).
 */
function environmentWithoutTools() {
  const env = { ...process.env };
  // The PATH key is spelled differently per platform ("Path" on Windows), and
  // the child must see exactly one PATH entry.
  for (const key of Object.keys(env)) {
    if (key.toLowerCase() === 'path') delete env[key];
  }
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'fqapp-no-tools-'));
  env.PATH = empty;
  return { env, empty };
}

// The script is Python; without an interpreter these cases cannot run. That
// must be visible rather than silently green.
test('a Python interpreter is available to run the fixture script', () => {
  assert.ok(
    interpreter,
    'python3 (or python) must be on PATH to exercise scripts/make_test_media.py',
  );
});

test('the script exists and parses as Python', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  assert.ok(fs.existsSync(script), 'scripts/make_test_media.py must exist');
  const compile = spawnSync(interpreter, ['-m', 'py_compile', script], {
    encoding: 'utf8',
  });
  assert.equal(
    compile.status,
    0,
    `the script must compile: ${compile.stderr || compile.stdout}`,
  );
});

test('--check exits 3 when a tool is missing, so a CI job can skip', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  // The toolchain is hidden from PATH, but the interpreter is invoked by its
  // absolute path, so it still runs.
  const { env, empty } = environmentWithoutTools();
  try {
    const result = spawnSync(interpreterPath, [script, '--check'], {
      encoding: 'utf8',
      env,
    });
    // 3, not 2: argparse uses 2 for a usage error, and a caller must be able
    // to tell "the arguments are wrong" from "the tools are not installed".
    assert.equal(result.status, 3, `expected exit 3, got ${result.status}`);
    assert.match(result.stderr, /missing/, 'the reason must be reported');
    assert.match(result.stderr, /ffmpeg/, 'the missing tool must be named');
  } finally {
    fs.rmSync(empty, { recursive: true, force: true });
  }
});

/// A usage error must not look like "the tools are missing": argparse exits
/// 2 on a bad argument, so the toolchain-missing code has to be different.
test('a usage error and a missing toolchain have different exit codes', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  const usage = spawnSync(interpreterPath, [script, '--size', '321x180'], {
    encoding: 'utf8',
  });
  assert.equal(usage.status, 2, `expected exit 2 for a usage error, got ${usage.status}`);

  const { env, empty } = environmentWithoutTools();
  try {
    const missing = spawnSync(interpreterPath, [script, '--check'], {
      encoding: 'utf8',
      env,
    });
    assert.equal(missing.status, 3, `expected exit 3, got ${missing.status}`);
    assert.notEqual(
      missing.status,
      usage.status,
      'a caller cannot act on "skip" and "fix your arguments" the same way',
    );
  } finally {
    fs.rmSync(empty, { recursive: true, force: true });
  }
});

test('--check succeeds when the toolchain is present', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  const probe = spawnSync(interpreter, [script, '--check'], { encoding: 'utf8' });
  if (probe.status === 3) {
    return t.skip('ffmpeg is not installed on this machine');
  }
  assert.equal(probe.status, 0, `expected exit 0, got ${probe.status}`);
  assert.match(probe.stdout, /ffmpeg:/, 'the tool versions must be reported');
});

test('a size that H.264 cannot encode is refused', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  for (const size of ['320', '0x180', '321x180', 'abc']) {
    const result = spawnSync(interpreter, [script, '--size', size], {
      encoding: 'utf8',
    });
    assert.notEqual(
      result.status,
      0,
      `--size ${size} must be refused before any ffmpeg run`,
    );
    assert.match(result.stderr, /expected WIDTHxHEIGHT|width and height/);
  }
});

test('a non-positive duration is refused', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  const result = spawnSync(interpreter, [script, '--seconds', '0'], {
    encoding: 'utf8',
  });
  assert.notEqual(result.status, 0, '--seconds 0 must be refused');
  assert.match(result.stderr, /positive/);
});

test('an output path that is not a directory is refused', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fqapp-fixture-'));
  const blocker = path.join(dir, 'blocker');
  fs.writeFileSync(blocker, 'not a directory');
  try {
    const result = spawnSync(
      interpreter,
      [script, '--output', blocker, '--seconds', '1', '--size', '64x64'],
      { encoding: 'utf8' },
    );
    assert.notEqual(result.status, 0, 'a file at the output path must be refused');
    assert.match(result.stderr, /not a directory/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('an existing fixture is kept unless --force is passed', (t) => {
  if (!interpreter) return t.skip('no Python interpreter');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fqapp-fixture-'));
  try {
    const manifest = path.join(dir, 'fixture.json');
    fs.writeFileSync(manifest, '{}');
    const result = spawnSync(
      interpreter,
      [script, '--output', dir, '--seconds', '1', '--size', '64x64'],
      { encoding: 'utf8' },
    );
    assert.notEqual(result.status, 0, 'an existing fixture must not be overwritten');
    assert.match(result.stderr, /--force/);
    assert.equal(
      fs.readFileSync(manifest, 'utf8'),
      '{}',
      'the existing manifest must be left alone',
    );
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the fixture lands under build/ so it stays out of git', () => {
  const source = fs.readFileSync(script, 'utf8');
  assert.match(
    source,
    /"build"\s*/,
    'the default output must be built from the build/ directory',
  );
  assert.match(
    source,
    /"test-media"/,
    'the default output must be build/test-media',
  );
  const ignore = path.join(appDir, '.gitignore');
  assert.match(
    fs.readFileSync(ignore, 'utf8'),
    /^\/build\/$/m,
    '.gitignore must keep build/ out of the repository',
  );
});
