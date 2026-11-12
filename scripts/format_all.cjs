#!/usr/bin/env node
'use strict';

const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const languages = ['dart', 'rust', 'javascript'];
const usage = `Usage: node scripts/format_all.cjs [--check] [--since <git-ref>] [--language all|dart|rust|javascript]

By default, format all supported tracked and non-ignored new source files.
--check       Report differences without writing files (exit 1).
--since REF   Select changes since the merge base of REF and HEAD, including
              staged, unstaged and non-ignored new files.
--language    Limit the formatter to one language (default: all).
--help        Show this help. Invalid arguments or unavailable tools exit 2.

Scope: Dart in lib/, test/, integration_test/, scripts/; Rust in rust/;
JavaScript in scripts/. Generated bindings and third-party code are excluded.
Setup: npm ci --ignore-scripts; see scripts/README.md for SDK versions.`;

function parseOptions() {
  const options = { check: false, since: null, language: 'all' };
  const args = process.argv.slice(2);
  for (let at = 0; at < args.length; at++) {
    const arg = args[at];
    if (arg === '--check') {
      options.check = true;
    } else if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else if (arg === '--since' || arg === '--language') {
      const value = args[++at];
      if (!value || value.startsWith('-')) {
        throw new Error(`${arg} requires a value.\n${usage}`);
      }
      options[arg.slice(2)] = value;
    } else {
      throw new Error(`Unknown argument: ${arg}\n${usage}`);
    }
  }
  if (options.language !== 'all' && !languages.includes(options.language)) {
    throw new Error(`Unknown language: ${options.language}\n${usage}`);
  }
  return options;
}

function git(args) {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function sourceLanguage(file) {
  if (
    file.startsWith('lib/src/rust/') ||
    /(?:^|\/)(?:third_party|build|target|node_modules)\//.test(file) ||
    /\.(?:g|freezed)\.dart$/.test(file) ||
    /(?:^|\/)frb_generated[^/]*\.rs$/.test(file)
  ) {
    return null;
  }
  if (/^(?:lib|test|integration_test|scripts)\/.*\.dart$/.test(file)) {
    return 'dart';
  }
  if (/^rust\/.*\.rs$/.test(file)) return 'rust';
  if (/^scripts\/.*\.(?:js|cjs|mjs)$/.test(file)) return 'javascript';
  return null;
}

function collectSources(options) {
  const untracked = git(['ls-files', '-z', '--others', '--exclude-standard'])
    .split('\0')
    .filter(Boolean);
  let files;
  if (options.since) {
    const commit = git([
      'rev-parse',
      '--verify',
      '--end-of-options',
      `${options.since}^{commit}`,
    ]).trim();
    const base = git(['merge-base', commit, 'HEAD']).trim();
    files = git([
      'diff',
      '--name-only',
      '-z',
      '--diff-filter=ACMRT',
      base,
      '--',
    ]);
  } else {
    files = git(['ls-files', '-z', '--cached']);
  }
  const groups = Object.fromEntries(
    languages.map((language) => [language, []]),
  );
  for (const file of [
    ...new Set([...files.split('\0'), ...untracked]),
  ].sort()) {
    const language = sourceLanguage(file);
    if (!language || !['all', language].includes(options.language)) continue;
    const absolute = path.join(root, file);
    if (!fs.existsSync(absolute) || !fs.lstatSync(absolute).isFile()) continue;
    groups[language].push(file);
  }
  return groups;
}

function dartExecutable() {
  if (process.platform !== 'win32') return 'dart';
  // Flutter exposes dart.bat on Windows. Invoke the SDK executable directly
  // so file names remain arguments, without cmd.exe quoting or its 8 KiB limit.
  const candidates = execFileSync('where.exe', ['dart'], { encoding: 'utf8' })
    .trim()
    .split(/\r?\n/);
  for (const candidate of candidates) {
    const resolved = fs.realpathSync(candidate);
    if (resolved.toLowerCase().endsWith('.exe')) return resolved;
    const sdk = path.join(
      path.dirname(resolved),
      'cache',
      'dart-sdk',
      'bin',
      'dart.exe',
    );
    if (fs.existsSync(sdk)) return sdk;
  }
  throw new Error(
    'Dart SDK not found. Run flutter precache or add the Dart SDK bin directory to PATH.',
  );
}

function command(executable, args, capture = false) {
  const result = spawnSync(executable, args, {
    cwd: root,
    encoding: 'utf8',
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    windowsHide: true,
  });
  if (result.error)
    throw new Error(`Cannot run ${executable}: ${result.error.message}`);
  if (result.signal || result.status === null) {
    throw new Error(`${executable} did not finish normally.`);
  }
  return result;
}

function prepareTools(groups, check) {
  const tools = {};
  if (groups.dart.length) {
    tools.dart = {
      executable: dartExecutable(),
      prefix: [],
      args: [
        'format',
        ...(check ? ['--output=none', '--set-exit-if-changed'] : []),
      ],
    };
  }
  if (groups.rust.length) {
    tools.rust = {
      executable: 'rustfmt',
      prefix: [],
      args: [
        '--config-path',
        path.join(root, 'rustfmt.toml'),
        // Stable rustfmt accepts skip_children on the CLI but ignores it in TOML.
        '--config',
        'skip_children=true',
        ...(check ? ['--check'] : []),
      ],
    };
  }
  if (groups.javascript.length) {
    const manifest = path.join(
      root,
      'node_modules',
      'prettier',
      'package.json',
    );
    const expected = require('../package.json').devDependencies.prettier;
    if (
      !fs.existsSync(manifest) ||
      JSON.parse(fs.readFileSync(manifest, 'utf8')).version !== expected
    ) {
      throw new Error(
        `Prettier ${expected} is required. Run npm ci --ignore-scripts in the repository root.`,
      );
    }
    tools.javascript = {
      executable: process.execPath,
      prefix: [path.join(path.dirname(manifest), 'bin', 'prettier.cjs')],
      args: [
        '--config',
        path.join(root, '.prettierrc.json'),
        check ? '--check' : '--write',
      ],
    };
  }
  // Check every required tool before any formatter is allowed to write.
  for (const [language, tool] of Object.entries(tools)) {
    const version = command(
      tool.executable,
      [...tool.prefix, '--version'],
      true,
    );
    if (version.status !== 0) {
      throw new Error(
        `${language} formatter is unavailable:\n${version.stderr || version.stdout}`,
      );
    }
    console.log(`${language}: ${(version.stdout || version.stderr).trim()}`);
  }
  return tools;
}

function formatDartNewlines(files, check) {
  let status = 0;
  // dart format preserves source line endings and has no LF override.
  for (const file of files) {
    const absolute = path.join(root, file);
    const source = fs.readFileSync(absolute, 'utf8');
    if (!source.includes('\r\n')) continue;
    if (check) {
      console.error(`Incorrect newline style: ${file} (expected LF)`);
      status = 1;
    } else {
      fs.writeFileSync(absolute, source.replace(/\r\n/g, '\n'));
      console.log(`Normalized LF: ${file}`);
    }
  }
  return status;
}

function main() {
  const options = parseOptions();
  if (options.help) {
    console.log(usage);
    return 0;
  }
  const groups = collectSources(options);
  const total = Object.values(groups).reduce(
    (count, files) => count + files.length,
    0,
  );
  if (!total) {
    if (!options.since) {
      throw new Error(
        'No supported source files found; refusing an empty full-format run.',
      );
    }
    console.log('No supported source files in the selected scope.');
    return 0;
  }
  const tools = prepareTools(groups, options.check);
  let status = 0;
  for (const [language, tool] of Object.entries(tools)) {
    const files = groups[language];
    console.log(
      `${options.check ? 'Checking' : 'Formatting'} ${files.length} ${language} files.`,
    );
    // Keep each invocation below Windows command-line limits. Explicit Rust
    // files plus skip_children cover modules without entering FRB output.
    for (let at = 0; at < files.length; at += 24) {
      const batch = files.slice(at, at + 24);
      const result = command(tool.executable, [
        ...tool.prefix,
        ...tool.args,
        ...batch,
      ]);
      status = Math.max(
        status,
        result.status === 0 ? 0 : options.check && result.status === 1 ? 1 : 2,
      );
      if (language === 'dart' && (options.check || result.status === 0)) {
        status = Math.max(status, formatDartNewlines(batch, options.check));
      }
    }
  }
  console.log(
    status === 0
      ? 'Formatting complete.'
      : 'Formatting failed; see the files and diagnostics above.',
  );
  return status;
}

try {
  process.exitCode = main();
} catch (error) {
  console.error(`format_all: ${error.message}`);
  process.exitCode = 2;
}
