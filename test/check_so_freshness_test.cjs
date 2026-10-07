// Guards for scripts/check_so_freshness.cjs (CRIT-011).
//
// The freshness check exists because a stale jniLibs core passes every other
// gate: Gradle only tests for the file's existence and the directory is
// gitignored. These cases pin the decision table so the guard cannot be
// loosened by accident.
//
// Run with: node --test test/check_so_freshness_test.cjs

'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { evaluateFreshness, parseArgs } = require('../scripts/check_so_freshness.cjs');

const HOUR = 60 * 60 * 1000;

test('a core newer than the newest rust/ change is accepted', () => {
  const verdict = evaluateFreshness({
    mtimeMs: 10 * HOUR,
    newestRustChangeMs: 9 * HOUR,
    allowMissing: false,
  });
  assert.equal(verdict.ok, true);
  assert.match(verdict.reason, /at least as new/);
});

test('a core older than the newest rust/ change is rejected', () => {
  // This is the v1.0.88 near-miss: the archived core predated 3187bfb.
  const verdict = evaluateFreshness({
    mtimeMs: 9 * HOUR,
    newestRustChangeMs: 10 * HOUR,
    allowMissing: false,
  });
  assert.equal(verdict.ok, false);
  assert.match(verdict.reason, /rebuild/);
});

test('a core built in the same second as the change counts as fresh', () => {
  const verdict = evaluateFreshness({
    mtimeMs: 10 * HOUR,
    newestRustChangeMs: 10 * HOUR,
    allowMissing: false,
  });
  assert.equal(verdict.ok, true);
});

test('no rust/ change in the range makes any existing core acceptable', () => {
  const verdict = evaluateFreshness({
    mtimeMs: 1 * HOUR,
    newestRustChangeMs: null,
    allowMissing: false,
  });
  assert.equal(verdict.ok, true);
  assert.match(verdict.reason, /no rust\/ change/);
});

test('a missing core is rejected when rust/ changed', () => {
  const verdict = evaluateFreshness({
    mtimeMs: null,
    newestRustChangeMs: 10 * HOUR,
    allowMissing: false,
  });
  assert.equal(verdict.ok, false);
  assert.match(verdict.reason, /missing/);
});

test('a missing core is tolerated only with --allow-missing', () => {
  const verdict = evaluateFreshness({
    mtimeMs: null,
    newestRustChangeMs: 10 * HOUR,
    allowMissing: true,
  });
  assert.equal(verdict.ok, true);
  assert.match(verdict.reason, /allow-missing/);
});

test('a missing core is fine when rust/ did not change either', () => {
  const verdict = evaluateFreshness({
    mtimeMs: null,
    newestRustChangeMs: null,
    allowMissing: false,
  });
  assert.equal(verdict.ok, true);
});

test('--since is mandatory and the library path is positional', () => {
  assert.throws(() => parseArgs(['core.so']), /usage/);
  assert.throws(() => parseArgs(['--since', 'HEAD']), /usage|needs/);
  assert.throws(() => parseArgs(['--since']), /needs a git ref/);
  assert.deepEqual(parseArgs(['core.so', '--since', 'v1.0.87']), {
    soPath: 'core.so',
    sinceRef: 'v1.0.87',
    allowMissing: false,
  });
  assert.deepEqual(parseArgs(['--allow-missing', 'core.so', '--since', 'main']), {
    soPath: 'core.so',
    sinceRef: 'main',
    allowMissing: true,
  });
});

test('unknown options are refused instead of silently ignored', () => {
  assert.throws(() => parseArgs(['core.so', '--since', 'HEAD', '--force']), /unknown option/);
});
