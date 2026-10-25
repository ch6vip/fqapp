'use strict';

// sp_atempo（FFmpeg af_atempo 的移植，issue #129）的宿主侧回归。
//
// 跑法：
//   NATIVE_CC=gcc node --test test/native_atempo_test.cjs
//
// 只验证算法本身，不涉及 Android：时长比例、幅度稳定性、纯音保真度、
// 拼接处没有爆音。真机听感仍需设备复测。
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { before, test } = require('node:test');

const root = path.resolve(__dirname, '..');
const outputDirectory = path.join(root, 'build', 'native-tests');
const executable = path.join(outputDirectory,
  process.platform === 'win32' ? 'atempo-vectors.exe' : 'atempo-vectors');
const compiler = process.env.NATIVE_CC || process.env.CC || 'cc';

/** 编译一个驱动。sources 是相对仓库根的源文件列表。 */
function build(name, sources, extraArgs) {
  const compilerFlags = /(?:^|[\/])zig(?:\.exe)?$/i.test(compiler) ? ['cc'] : [];
  const output = path.join(outputDirectory, name);
  compilerFlags.push('-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
    ...(extraArgs || []),
    ...sources.map((source) => path.join(root, source)),
    '-I', path.join(root, 'native', 'audio_tempo'),
    '-I', path.join(root, 'native', 'third_party', 'kissfft'),
    '-lm',
    '-o', output);
  const compiled = spawnSync(compiler, compilerFlags, {
    cwd: root,
    encoding: 'utf8',
    timeout: 180_000,
    windowsHide: true,
  });
  assert.equal(compiled.error, undefined,
    `Set NATIVE_CC to a host C compiler (cc, clang, gcc, zig). ${compiled.error || ''}`);
  assert.equal(compiled.status, 0, compiled.stderr || compiled.stdout);
  return output;
}

const kissfftSources = [
  'native/third_party/kissfft/kiss_fft.c',
  'native/third_party/kissfft/kiss_fftr.c',
];

let resampleExecutable;
let resumeExecutable;

function compile() {
  mkdirSync(outputDirectory, { recursive: true });
  // kissfft 是原样 vendored 的第三方源码，它自带一处有符号比较告警。
  build('atempo-vectors', [
    'native/tests/atempo_vectors.c',
    'native/audio_tempo/sp_atempo.c',
    ...kissfftSources,
  ], ['-Wno-sign-compare']);
  resampleExecutable = build('resample-vectors', [
    'native/tests/resample_vectors.c',
    'native/audio_tempo/sp_resample.c',
  ]);
  resumeExecutable = build('flush-resume', [
    'native/tests/flush_resume.c',
    'native/audio_tempo/sp_atempo.c',
    ...kissfftSources,
  ], ['-Wno-sign-compare']);
}

before(compile);

/** 跑一次驱动，返回 key=value 的解析结果。 */
function run(sampleRate, channels, tempo, freq, seconds) {
  const result = spawnSync(executable,
    [String(sampleRate), String(channels), String(tempo), String(freq), String(seconds)],
    { encoding: 'utf8', timeout: 120_000, windowsHide: true });
  assert.equal(result.status, 0,
    `driver failed (status ${result.status}): ${result.stderr}`);
  const values = {};
  for (const line of result.stdout.split('\n')) {
    // 行尾可能带 CR：trim() 已经抹掉。
    const match = /^([a-z_0-9]+)=(-?[\d.]+)\s*$/.exec(line.trim());
    if (match) values[match[1]] = Number(match[2]);
  }
  return values;
}

test('时伸缩不改变输出时长比例', () => {
  // 官方 atempo 的语义：输出样本数 ≈ 输入 / tempo。
  for (const tempo of [0.75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
    const r = run(48000, 1, tempo, 440, 3);
    assert.ok(r.duration_ratio > 0.95 && r.duration_ratio < 1.06,
      `tempo=${tempo} 时长比 ${r.duration_ratio} 超出 ±6%`);
  }
});

test('时伸缩不衰减幅度', () => {
  // WSOLA 的 Hann 窗重叠相加必须保持能量；掉一半说明归一到不了 1。
  for (const tempo of [1.0, 1.5, 2.0, 3.0]) {
    const r = run(48000, 1, tempo, 440, 3);
    const ratio = r.output_rms / r.input_rms;
    assert.ok(ratio > 0.85 && ratio < 1.15,
      `tempo=${tempo} RMS 比 ${ratio.toFixed(3)} 超出 ±15%`);
  }
});

test('纯音经过时伸缩后仍是同一个音', () => {
  // 440 Hz 输入，输出必须能用一个 440 Hz 正弦解释（R² 高）。
  // 这条是「电音」的客观代理：波形被破坏时 R² 会崩。
  for (const tempo of [1.0, 1.25, 1.5, 2.0, 3.0]) {
    const r = run(48000, 1, tempo, 440, 3);
    assert.ok(r.tone_r2 > 0.85,
      `tempo=${tempo} 纯音保真度 R²=${r.tone_r2} 过低`);
  }
});

test('拼接处不产生爆音', () => {
  // 相邻样本的最大跳变不应超过输入本身的最大跳变（差 1 是取整误差）。
  for (const tempo of [1.0, 1.5, 2.0, 3.0]) {
    const r = run(48000, 1, tempo, 440, 3);
    assert.ok(r.output_max_step <= r.input_max_step + 2,
      `tempo=${tempo} 输出最大阶跃 ${r.output_max_step} > 输入 ${r.input_max_step}，拼接点可能错位`);
  }
});

test('窗口按 sample_rate / 24 推圆到 2 的幂，与官方一致', () => {
  // 官方 yae_reset：window = sample_rate/24，再向上取到 2 的幂。
  const cases = [
    [22050, 1024],
    [24000, 1024],
    [44100, 2048],
    [48000, 2048],
    [16000, 1024],
  ];
  for (const [rate, expected] of cases) {
    const r = run(rate, 1, 2.0, 440, 1);
    assert.equal(r.window, expected, `sample_rate=${rate} 的窗口应为 ${expected}`);
  }
});

test('立体声与单声道给出同样的时长比例', () => {
  const mono = run(48000, 1, 2.0, 440, 2);
  const stereo = run(48000, 2, 2.0, 440, 2);
  assert.ok(Math.abs(mono.duration_ratio - stereo.duration_ratio) < 0.05,
    `单声道 ${mono.duration_ratio} 与立体声 ${stereo.duration_ratio} 差距过大`);
});

/** 跑一次重采样驱动。 */
function runResample(inRate, outRate, channels, freq, seconds) {
  const result = spawnSync(resampleExecutable,
    [String(inRate), String(outRate), String(channels), String(freq), String(seconds)],
    { encoding: 'utf8', timeout: 120_000, windowsHide: true });
  assert.equal(result.status, 0,
    `resample driver failed (status ${result.status}): ${result.stderr}`);
  const values = {};
  for (const line of result.stdout.split('\n')) {
    const match = /^([a-z_0-9]+)=(-?[\d.]+)\s*$/.exec(line.trim());
    if (match) values[match[1]] = Number(match[2]);
  }
  return values;
}

test('变速前置重采样：帧数比例与目标一致', () => {
  // 这一级是官方的 samplefilter（atempo 之前统一采样率）。
  for (const [inRate, outRate] of [
    [24000, 48000],
    [22050, 48000],
    [44100, 48000],
    [16000, 48000],
    [48000, 48000],
  ]) {
    const r = runResample(inRate, outRate, 1, 440, 2);
    const expected = outRate / inRate;
    assert.ok(Math.abs(r.ratio - expected) < 0.01,
      `${inRate}->${outRate} 比例 ${r.ratio} 偏离 ${expected.toFixed(4)}`);
  }
});

test('变速前置重采样不改变音高', () => {
  for (const [inRate, outRate] of [[24000, 48000], [22050, 48000], [44100, 48000]]) {
    const r = runResample(inRate, outRate, 1, 440, 2);
    assert.ok(Math.abs(r.out_freq - 440) < 5,
      `${inRate}->${outRate} 输出频率 ${r.out_freq}Hz 偏离 440Hz`);
  }
});

test('变速前置重采样不产生爆音', () => {
  // 线性插值只会让相邻样本差变小（升采样）或翻倍（降采样），
  // 出现远大于输入的跳变说明相位跳帧。
  for (const [inRate, outRate] of [[24000, 48000], [44100, 48000], [48000, 48000]]) {
    const r = runResample(inRate, outRate, 1, 440, 2);
    assert.ok(r.out_max_step <= r.in_max_step * 2 + 4,
      `${inRate}->${outRate} 输出最大阶跃 ${r.out_max_step} 远超输入 ${r.in_max_step}`);
  }
});

test('变速前置重采样保持幅度', () => {
  for (const [inRate, outRate] of [[24000, 48000], [22050, 48000]]) {
    const r = runResample(inRate, outRate, 1, 440, 2);
    const ratio = r.out_rms / r.in_rms;
    assert.ok(ratio > 0.9 && ratio < 1.1,
      `${inRate}->${outRate} RMS 比 ${ratio.toFixed(3)} 超出 ±10%`);
  }
});

test('长缓冲不溢出（相位是 64 位）', () => {
  // 回归：32 位相位在 48k->48k 且单块超过约 6.5 万帧时回绕，
  // 表现为多吐 2 个样本并读到缓冲区外（爆音）。
  const r = runResample(48000, 48000, 1, 440, 5); // 24 万帧
  assert.equal(r.out_frames, r.in_frames,
    `48k->48k 应逐帧恒等，实际 ${r.out_frames} vs ${r.in_frames}`);
});

test('flush 之后继续喂输入仍能产帧（seek / 循环播放）', () => {
  // 回归：yae_flush 把状态置为 YAE_FLUSH_OUTPUT，而 yae_apply 只匹配
  // LOAD/ADJUST/RELOAD/OVERLAP_ADD 四种，flush 之后再喂数据会卡死状态机
  // （修复前这个驱动直接超时）。用户侧表现为「拖完进度条之后没声音」。
  const result = spawnSync(resumeExecutable, [], {
    encoding: 'utf8', timeout: 60_000, windowsHide: true,
  });
  assert.equal(result.status, 0, `driver failed: ${result.stderr}`);
  const values = {};
  for (const line of result.stdout.split('\n')) {
    const match = /^([a-z_]+)=(-?[\d.]+)\s*$/.exec(line.trim());
    if (match) values[match[1]] = Number(match[2]);
  }
  assert.ok(values.first_segment_frames > 0, '第一段应当产出音频');
  assert.ok(values.second_segment_frames > 0,
    `flush 之后必须还能产帧，实际 ${values.second_segment_frames}`);
  const ratio = values.second_segment_frames / values.first_segment_frames;
  assert.ok(ratio > 0.8 && ratio < 1.2,
    `flush 前后产出量差异过大: ${ratio.toFixed(3)}`);
});
