#!/usr/bin/env node
'use strict';

// Guards CRIT-011: the packaged Android Rust core must not be older than the
// newest rust/ source change.
//
// Gradle only checks that jniLibs/arm64-v8a/libfqapi_core.so exists; it never
// recompiles it, and that directory is gitignored. Releasing therefore needs an
// explicit rebuild whenever rust/ moved since the last archive, or the APK ships
// without the latest Rust fix while every other gate stays green.
//
// Usage:
//   node scripts/check_so_freshness.cjs <path-to-libfqapi_core.so> --since <git-ref>
//   node scripts/check_so_freshness.cjs <path> --since <ref> --allow-missing
//   node scripts/check_so_freshness.cjs <path> --since <ref> --expect-sha256 <hex>
//
// Deliberately NOT wired into CI: CI rebuilds the Rust core from source on
// every run, so a freshness gate there would check nothing real.
//
// Limitation: mtime is NOT content proof. A `touch`, clock skew, or a rebuild
// from different source that lands on the same mtime can all fool the mtime
// comparison, and the git-log comparison only sees committed rust/ changes
// (uncommitted files are covered only by their mtime). Treat this script as a
// fast local pre-check, never as proof the library contains given source.
// The reliable gates are rebuilding from source (what CI does) or comparing
// content with --expect-sha256 against a hash recorded at build time.
// Exits 0 when the library is at least as new as the newest rust/ change in
// `<ref>..HEAD`, 1 when it is stale, and 2 on bad usage. ELF layout is a
// separate concern: see check_native_alignment.cjs.

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');

/**
 * Pure decision step, kept separate so tests can exercise it without git.
 *
 * @param {{mtimeMs: number|null, newestRustChangeMs: number|null, allowMissing: boolean}} input
 * @returns {{ok: boolean, reason: string}}
 */
function evaluateFreshness({ mtimeMs, newestRustChangeMs, allowMissing }) {
  if (newestRustChangeMs === null) {
    return { ok: true, reason: 'no rust/ change in the range; the existing core is acceptable' };
  }
  if (mtimeMs === null) {
    return allowMissing
      ? { ok: true, reason: 'library missing but --allow-missing was given' }
      : { ok: false, reason: 'library missing while rust/ changed; rebuild it' };
  }
  if (mtimeMs < newestRustChangeMs) {
    return { ok: false, reason: 'library is older than the newest rust/ change; rebuild it' };
  }
  return { ok: true, reason: 'library is at least as new as the newest rust/ change' };
}

/**
 * Content-hash comparison, the mtime check's stronger companion. Pure, kept
 * separate so tests can exercise it without a file on disk.
 */
function checkHash({ actualSha256, expectSha256 }) {
  if (expectSha256 === null) {
    return { ok: true, reason: 'no expected hash given' };
  }
  if (actualSha256 === null) {
    return { ok: false, reason: 'library missing; cannot compare content hash' };
  }
  return actualSha256 === expectSha256
    ? { ok: true, reason: 'library content hash matches the expected hash' }
    : { ok: false, reason: 'library content hash does not match the expected hash; rebuild it' };
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}
function newestRustChangeMs(sinceRef, cwd) {
  let out;
  try {
    out = execFileSync(
      'git',
      ['log', '-1', '--format=%ct', `${sinceRef}..HEAD`, '--', 'rust/'],
      { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
    ).trim();
  } catch (error) {
    throw new Error(`git log failed for range ${sinceRef}..HEAD: ${error.message}`);
  }
  if (out === '') return null;
  const seconds = Number(out);
  if (!Number.isFinite(seconds)) throw new Error(`unexpected git timestamp: ${out}`);
  return seconds * 1000;
}

function parseArgs(argv) {
  const positional = [];
  let sinceRef = null;
  let allowMissing = false;
  let expectSha256 = null;
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--since') {
      sinceRef = argv[++i];
      if (!sinceRef) throw new Error('--since needs a git ref');
    } else if (arg === '--allow-missing') {
      allowMissing = true;
    } else if (arg === '--expect-sha256') {
      const raw = argv[++i];
      if (!raw) throw new Error('--expect-sha256 needs a SHA-256 hex digest');
      expectSha256 = raw.toLowerCase();
      if (!/^[0-9a-f]{64}$/.test(expectSha256)) {
        throw new Error('--expect-sha256 must be a 64-digit hex SHA-256 digest');
      }
    } else if (arg.startsWith('--')) {
      throw new Error(`unknown option: ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  if (positional.length !== 1 || !sinceRef) {
    throw new Error('usage: check_so_freshness.cjs <libfqapi_core.so> --since <git-ref> [--allow-missing] [--expect-sha256 <hex>]');
  }
  return { soPath: positional[0], sinceRef, allowMissing, expectSha256 };
}

function main(argv) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    return 2;
  }

  const repoRoot = execFileSync('git', ['rev-parse', '--show-toplevel'], {
    cwd: process.cwd(),
    encoding: 'utf8',
  }).trim();
  const soPath = path.resolve(repoRoot, options.soPath);

  let mtimeMs = null;
  if (fs.existsSync(soPath)) mtimeMs = fs.statSync(soPath).mtimeMs;

  const newest = newestRustChangeMs(options.sinceRef, repoRoot);
  const verdict = evaluateFreshness({
    mtimeMs,
    newestRustChangeMs: newest,
    allowMissing: options.allowMissing,
  });

  const iso = (ms) => (ms === null ? 'n/a' : new Date(ms).toISOString());
  process.stdout.write(`core: ${soPath}\n`);
  process.stdout.write(`core mtime: ${iso(mtimeMs)}\n`);
  process.stdout.write(`newest rust/ change in ${options.sinceRef}..HEAD: ${iso(newest)}\n`);
  process.stdout.write(`${verdict.ok ? 'OK' : 'STALE'}: ${verdict.reason}\n`);

  // The hash comparison is independent of the mtime verdict: a matching hash
  // does not rescue a stale mtime, and a fresh mtime does not rescue a hash
  // mismatch. Either failure exits non-zero.
  if (options.expectSha256 !== null) {
    const actual = fs.existsSync(soPath) ? sha256File(soPath) : null;
    const hashVerdict = checkHash({ actualSha256: actual, expectSha256: options.expectSha256 });
    process.stdout.write(`core sha256: ${actual ?? 'n/a'}\n`);
    process.stdout.write(`${hashVerdict.ok ? 'OK' : 'MISMATCH'}: ${hashVerdict.reason}\n`);
    if (!hashVerdict.ok) return 1;
  }

  return verdict.ok ? 0 : 1;
}

if (require.main === module) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 2;
  }
}

module.exports = { evaluateFreshness, parseArgs, sha256File, checkHash };
