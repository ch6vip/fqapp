// Guards for the Rust core build scripts.
//
// Replaces the retired test/build_backend_scripts_test.cjs: the checks that are
// still valuable (one canonical build entry point per platform, pinned
// toolchain, a deterministic output path) are kept, and the Go-specific
// assertions are replaced by Rust/FRB ones.
//
// Run with: node --test test/build_rust_backend_scripts_test.cjs

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const appDir = path.resolve(__dirname, '..');
const scriptsDir = path.join(appDir, 'scripts');

function readScript(name) {
  return fs.readFileSync(path.join(scriptsDir, name), 'utf8');
}

test('exactly one Rust build entry point exists per platform', () => {
  for (const name of ['build_rust_backend.ps1', 'build_rust_backend.sh']) {
    assert.ok(
      fs.existsSync(path.join(scriptsDir, name)),
      `${name} must exist`,
    );
  }
  for (const retired of ['build_backend.ps1', 'build_backend.sh']) {
    assert.ok(
      !fs.existsSync(path.join(scriptsDir, retired)),
      `${retired} must be removed: the Go build chain is gone`,
    );
  }
});

test('the build scripts pin the same flutter_rust_bridge version as the crate', () => {
  const crate = fs.readFileSync(
    path.join(appDir, 'rust', 'Cargo.toml'),
    'utf8',
  );
  const crateVersion = /flutter_rust_bridge\s*=\s*"=([0-9.]+)"/.exec(crate);
  assert.ok(crateVersion, 'rust/Cargo.toml must pin an exact FRB version');

  for (const name of ['build_rust_backend.ps1', 'build_rust_backend.sh']) {
    const source = readScript(name);
    assert.ok(
      source.includes(crateVersion[1]),
      `${name} must reference FRB ${crateVersion[1]}`,
    );
  }

  const yaml = fs.readFileSync(
    path.join(appDir, 'flutter_rust_bridge.yaml'),
    'utf8',
  );
  assert.match(yaml, /rust_input:\s*crate::api/);
  assert.match(yaml, /dart_output:\s*lib\/src\/rust/);
  assert.match(yaml, /web:\s*false/);
});

test('the build scripts target Android ARM64 with the project NDK and 16 KiB pages', () => {
  for (const name of ['build_rust_backend.ps1', 'build_rust_backend.sh']) {
    const source = readScript(name);
    assert.ok(source.includes('aarch64-linux-android'), name);
    assert.ok(source.includes('28.2.13676358'), `${name} must pin the project NDK`);
    assert.ok(
      source.includes('libfqapi_core.so'),
      `${name} must produce libfqapi_core.so`,
    );
    assert.ok(
      source.includes('jniLibs') && source.includes('arm64-v8a'),
      `${name} must install into jniLibs/arm64-v8a`,
    );
  }

  const cargoConfig = fs.readFileSync(
    path.join(appDir, 'rust', '.cargo', 'config.toml'),
    'utf8',
  );
  assert.match(
    cargoConfig,
    /max-page-size=16384/,
    'the Android target must link with 16 KiB page alignment',
  );
});

test('the product build no longer depends on Go or the private backend', () => {
  const workflow = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  assert.ok(
    !/setup-go|golang|build_backend/.test(workflow),
    'the APK workflow must not install Go or build the Go backend',
  );
  assert.ok(
    workflow.includes('build_rust_backend.sh'),
    'the APK workflow must build the Rust core',
  );
  assert.ok(
    workflow.includes('flutter_rust_bridge_codegen generate'),
    'the APK workflow must regenerate and verify the bridge bindings',
  );

  assert.ok(
    !fs.existsSync(path.join(appDir, 'assets', 'bin')),
    'the removed assets/bin directory must not come back',
  );
  const pubspec = fs.readFileSync(path.join(appDir, 'pubspec.yaml'), 'utf8');
  assert.ok(
    !pubspec.includes('assets/bin/'),
    'pubspec must not declare the removed assets/bin directory',
  );
});

test('the APK verifier expects the Rust core library', () => {
  const verifier = fs.readFileSync(
    path.join(appDir, 'scripts', 'verify_android_apk.py'),
    'utf8',
  );
  assert.ok(verifier.includes('lib/arm64-v8a/libfqapi_core.so'));
});

test('the Rust build script survives cargo writing progress to stderr', () => {
  // CRIT-012: $ErrorActionPreference = 'Stop' turns cargo's stderr progress into
  // a NativeCommandError that aborts the script before the copy step, so a
  // successful compile looks like a failed build. Native calls must go through
  // the wrapper that downgrades the preference and judges on $LASTEXITCODE.
  const source = readScript('build_rust_backend.ps1');
  assert.ok(
    source.includes('function Invoke-NativeCommand'),
    'the script must define a native-command wrapper',
  );
  assert.ok(
    /function Invoke-NativeCommand[\s\S]*?\$ErrorActionPreference = 'Continue'[\s\S]*?\$LASTEXITCODE/.test(
      source,
    ),
    'the wrapper must downgrade the preference and check the exit code',
  );
  assert.ok(
    source.includes("Invoke-NativeCommand -Exe 'flutter_rust_bridge_codegen'"),
    'the codegen call must go through the wrapper',
  );
  assert.ok(
    !/^\s*cargo build /m.test(source),
    'no bare cargo invocation may remain: it would abort on stderr progress',
  );
});

test('a stale Android Rust core can be detected before packaging', () => {
  // CRIT-011: Gradle only checks that the core exists, so the freshness guard is
  // the only thing standing between a backfill release and a silently stale APK.
  const guard = fs.readFileSync(
    path.join(scriptsDir, 'check_so_freshness.cjs'),
    'utf8',
  );
  assert.ok(guard.includes("'rust/'"), 'the guard must scope git log to rust/');
  assert.ok(guard.includes('--since'), 'the guard must take the archive ref');
  assert.ok(
    guard.includes('module.exports'),
    'the guard must export its decision step for tests',
  );
});
