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
const { spawnSync } = require('node:child_process');

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

test('the build scripts target Android ARM64 + ARMv7 with the project NDK and 16 KiB pages', () => {
  for (const name of ['build_rust_backend.ps1', 'build_rust_backend.sh']) {
    const source = readScript(name);
    assert.ok(source.includes('aarch64-linux-android'), name);
    assert.ok(source.includes('armv7-linux-androideabi'), `${name} must build the 32-bit ARM target`);
    assert.ok(source.includes('28.2.13676358'), `${name} must pin the project NDK`);
    assert.ok(
      source.includes('libfqapi_core.so'),
      `${name} must produce libfqapi_core.so`,
    );
    assert.ok(
      source.includes('jniLibs') && source.includes('arm64-v8a') && source.includes('armeabi-v7a'),
      `${name} must install into jniLibs/arm64-v8a and jniLibs/armeabi-v7a`,
    );
  }

  const cargoConfig = fs.readFileSync(
    path.join(appDir, '.cargo', 'config.toml'),
    'utf8',
  );
  assert.match(
    cargoConfig,
    /\[target\.armv7-linux-androideabi\][\s\S]*?max-page-size=16384/,
    'the 32-bit Android target must link with 16 KiB page alignment',
  );
  assert.match(
    cargoConfig,
    /\[target\.aarch64-linux-android\][\s\S]*?max-page-size=16384/,
    'the 64-bit Android target must link with 16 KiB page alignment',
  );
});

test('the APK workflow builds and verifies both ABIs', () => {
  const workflow = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  assert.ok(
    workflow.includes('armv7-linux-androideabi'),
    'the APK workflow must install the 32-bit Rust target',
  );
  assert.ok(
    workflow.includes('--split-per-abi'),
    'the APK workflow must split the APK per ABI instead of shipping one arm64-only package',
  );
  assert.ok(
    workflow.includes('app-$abi-release.apk') || workflow.includes('app-armeabi-v7a-release.apk'),
    'the APK workflow must verify the 32-bit APK',
  );
  assert.ok(
    workflow.includes('fqapp-armv7-'),
    'the APK workflow must upload a separate 32-bit artifact',
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

test('the APK verifier expects the Rust core library for both ABIs', () => {
  const verifier = fs.readFileSync(
    path.join(appDir, 'scripts', 'verify_android_apk.py'),
    'utf8',
  );
  assert.ok(verifier.includes('lib/arm64-v8a/libfqapi_core.so'));
  assert.ok(verifier.includes('lib/armeabi-v7a/libfqapi_core.so'));
});

test('APK unsigned classification accepts Gradle output and rejects damaged signatures', () => {
  const python = process.platform === 'win32' ? 'python' : 'python3';
  const result = spawnSync(python, ['-m', 'unittest', 'discover', '-s', 'test',
    '-p', 'verify_android_apk_test.py', '-v'], {
    cwd: appDir, encoding: 'utf8', timeout: 30000,
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
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

test('the APK workflow fetches tags before the version-monotonicity gate', () => {
  // The gate reads `git tag --list 'v*'`, and actions/checkout defaults to
  // `--depth=1 --no-tags`, which makes that list empty. An empty list is not a
  // failure: the gate then compares against nothing and passes. So the tags
  // must be fetched explicitly, and `fetch-tags: true` is NOT enough -- it
  // still runs under --depth=1, which resolves only tags reachable from the
  // fetched tip (verified: 0 tags after a depth-1 --no-tags clone, 8 after
  // `git fetch --tags`).
  const workflow = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  // Search the parsed step commands, not the raw file: the comment above the
  // step also mentions `git fetch --tags`, so a substring match on the whole
  // document would still pass after the step itself was deleted.
  const commands = workflow
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('#'))
    .join('\n');
  assert.ok(
    commands.includes('git fetch --tags'),
    'the APK workflow must fetch tags; without it the monotonicity gate is dead',
  );
  assert.ok(
    commands.indexOf('git fetch --tags') < commands.indexOf('highest_tag='),
    'tags must be fetched before the gate reads git tag --list',
  );
});

test('the APK workflow shares the Dart gate with a parallel job', () => {
  // flutter test is the single largest step of the run. It needs only the
  // Flutter SDK, so serialising it behind the NDK/Gradle/Rust setup wasted
  // wall-clock time. It must stay a FULL run, not a reduced suite.
  const workflow = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  assert.ok(
    /^\s{2}dart-gate:/m.test(workflow),
    'the Dart gate must be its own job so it can run in parallel with apk',
  );
  assert.ok(
    /flutter test --no-pub --concurrency=4 --reporter compact/.test(workflow),
    'the Dart gate must run the full suite on all four cores',
  );
  assert.ok(
    !/flutter analyze --no-pub\n\s+flutter test/.test(workflow),
    'analyze and test must not run inside the apk job again',
  );
});

test('the APK workflow cache paths do not use parse-time env expansion', () => {
  // ${{ env.ANDROID_HOME }} is expanded at PARSE time, but ANDROID_HOME is only
  // injected into the job at RUN time by the runner image. The expression
  // therefore resolved to an empty string and the cache paths became
  // /ndk/<ver> and /cmake/<ver>; actions/cache then refused to save anything
  // ("Path(s) specified in the action for caching do(es) not exist"), so both
  // caches never worked while still costing two steps per run. Verified in run
  // 40123765356: `path: /ndk/28.2.13676358`.
  const workflow = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  // Strip comments first: the explanatory comment above the cache steps also
  // spells out `${{ env.ANDROID_HOME }}`, and matching the whole document would
  // fail on that even when no step actually uses it.
  const spec = workflow
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('#'))
    .join('\n');
  assert.ok(
    !/\$\{\{\s*env\.ANDROID_HOME\s*\}\}/.test(spec),
    'ANDROID_HOME must not be used in ${{ }}: it is empty at parse time',
  );
  assert.ok(
    spec.includes('/usr/local/lib/android/sdk/ndk/'),
    'the NDK cache must use the documented runner image path',
  );
  assert.ok(
    spec.includes('/usr/local/lib/android/sdk/cmake/'),
    'the CMake cache must use the documented runner image path',
  );
});

test('the APK job keeps the measured Gradle worker limits', () => {
  // 4 workers was measured on the real 4-vCPU runner and was slower than 2:
  // release APK compile 220s -> 342s, :app:testDebugUnitTest 66s -> 91s.
  const workflow = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  assert.ok(
    workflow.includes('-Dorg.gradle.workers.max=2'),
    'workers.max=4 regressed the APK build; keep the measured value of 2',
  );
  assert.ok(
    /CMAKE_BUILD_PARALLEL_LEVEL: '2'/.test(workflow),
    'CMAKE_BUILD_PARALLEL_LEVEL=4 regressed the APK build; keep 2',
  );
});

test('workflow path filters are defined once and referenced by anchor', () => {
  // push 和 pull_request 下各抄一份 paths 时，加一条路径要改两处，漏一处就会
  // 变成「PR 跑、master 不跑」，而没有任何测试能发现。两个 workflow 现在都
  // 只在 push 下定义 &anchor，pull_request 用 *anchor 引用。
  const cases = [
    { file: 'android-apk.yml', anchor: 'app_paths' },
    { file: 'windows.yml', anchor: 'windows_paths' },
    { file: 'native-crypto.yml', anchor: 'native_paths' },
  ];
  for (const { file, anchor } of cases) {
    const workflow = fs.readFileSync(
      path.join(appDir, '.github', 'workflows', file),
      'utf8',
    );
    // 用 split 数出现次数而不是正则：模板字符串里写 \b 会变成退格符。
    const definitions = workflow.split(`paths: &${anchor}`).length - 1;
    assert.equal(definitions, 1, `${file} must define paths once as &${anchor}`);
    const references = workflow.split(`paths: *${anchor}`).length - 1;
    assert.equal(
      references,
      1,
      `${file} must reference the same list with *${anchor}`,
    );
    assert.ok(
      workflow.indexOf(`&${anchor}`) < workflow.indexOf(`*${anchor}`),
      `${file} must define &${anchor} before referencing it`,
    );
  }
});

test('the size budget gate runs in the Dart gate, not the Windows build', () => {
  // 行数预算只读源码，不依赖 Windows 工具链；绑在 windows.yml 上就要排在
  // ffmpeg 下载后面。它必须留在 dart-gate，否则这个门禁会随 Windows job 一起
  // 被跳过或拖慢。
  const apk = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'android-apk.yml'),
    'utf8',
  );
  const dartGate = apk.slice(apk.lastIndexOf('dart-gate:'));
  assert.ok(
    dartGate.includes('bash scripts/check_line_budget.sh'),
    'the dart-gate job must run scripts/check_line_budget.sh',
  );
  const windows = fs.readFileSync(
    path.join(appDir, '.github', 'workflows', 'windows.yml'),
    'utf8',
  );
  assert.ok(
    !windows.includes('check_line_budget'),
    'the Windows job must not run the size budget again',
  );
});
