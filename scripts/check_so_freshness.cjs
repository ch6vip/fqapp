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
//
// Exits 0 when the library is at least as new as the newest rust/ change in
// `<ref>..HEAD`, 1 when it is stale, and 2 on bad usage. ELF layout is a
// separate concern: see check_native_alignment.cjs.

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
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

/** Committer date of the newest commit touching rust/, or null when none. */
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
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--since') {
      sinceRef = argv[++i];
      if (!sinceRef) throw new Error('--since needs a git ref');
    } else if (arg === '--allow-missing') {
      allowMissing = true;
    } else if (arg.startsWith('--')) {
      throw new Error(`unknown option: ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  if (positional.length !== 1 || !sinceRef) {
    throw new Error('usage: check_so_freshness.cjs <libfqapi_core.so> --since <git-ref> [--allow-missing]');
  }
  return { soPath: positional[0], sinceRef, allowMissing };
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

module.exports = { evaluateFreshness, parseArgs };
