# sp_atempo — WSOLA 时伸缩

听书倍速的实现（issue #129），移植自 FFmpeg 7.1 的
`libavfilter/af_atempo.c`（Copyright (c) 2012 Pavel Koshevoy，
**LGPL-2.1-or-later**，原文保留在仓库的 `COPYING.LGPL-2.1`）。

## 为什么是这一份

番茄免费小说 7.0.9.32 的听书倍速就是这条路（反编译取证）：

```
com.xs.fm.player.sdk.play.player.audio.engine.g.setPlaySpeed
  -> PlaybackParams().setPitch(1.0f).setSpeed(speed/100f)
  -> TTPlayerClient.setPlaybackParams -> mPlayer.setFloatOption(60, speed)
  -> native: avfilter_get_by_name("atempo"), "tempo=%1.2f"
             aformat -> atempo -> abuffersink
```

`libttmplayer.so` 里能读到 `atempo`、`avfilter_graph_create_filter`、
`build ppl: in-sampleRate: %d, out-sampleRate: %d, ..., speed: %f`。
要用同样的听感，就得用同样的算法与同样的窗口参数。

## 与上游的差异

| 上游 | 这里 |
|---|---|
| `AVFilterContext` / `AVFrame` 管线 | `sp_atempo_*` 的 push/pull 接口 |
| `av_tx_init(AV_TX_FLOAT_RDFT)` | kissfft `kiss_fftr` / `kiss_fftri` |
| `av_calloc` / `av_log2` / `AVComplexFloat` | `calloc` / 本地宏 / 交错 float 数组 |
| 5 种采样格式 | 只保留 S16（ExoPlayer AudioProcessor 的唯一格式） |

`yae_*` 系列的状态机、窗口推导（`sample_rate / 24` 向上取到 2 的幂）、
Hann 窗、归一化互相关（`drifti * (i-i0) * (i1-i)`）与上游逐行一致。

**一个必须注意的坑**：上游 `av_tx_init` 的 `scale` / `iscale` 都是 1.0，
即正逆变换都不归一化；`kiss_fftri` 内部会除以 nfft。`yae_xcorr_via_rdft`
末尾乘回 `nfft` 抹平差异——漏了会让相关值整体缩小 nfft 倍，权重项主导
对齐搜索，选错拼接点后波形被破坏（表现为时长正常但严重失真）。

## 变速前置重采样（sp_resample.c）

官方在 atempo 之前把 PCM 统一到采样率——`libttmplayer.so` 里能看到
`FFSampleFilter`（`start samplefilter %p, src samplerate:%d ... dst samplerate:%d`）
与它内部的 `aformat` 节点（`sample_rates=%d:channel_layouts=0x%lx:sample_fmts=%s`）。
目标速率来自 `getNativeOutputSampleRate`，也就是**设备原生输出采样率**，
不是写死的 48 kHz——否则 AudioTrack 会再隐式重采样一次。

本仓库对应 `NativePlayerPlugin.nativeOutputSampleRate()`
（`AudioTrack.getNativeOutputSampleRate(STREAM_MUSIC)`，失败退回 48 kHz），
经 `WsolaProcessorChain` 传进 `SpeechTempoProcessor` 作为 targetRate。

没有这一级时，WSOLA 的窗口（`sample_rate / 24`）在 24 kHz 的音源上只有
1024 点，比 48 kHz 的 2048 点少一半，周期估计更粗。实测本项目的 TTS 与
书籍音频都是 48 kHz（`resample=false`），这一级当前是空操作，保留它是
为了设备原生率不是 48 kHz 的机型。

`sp_resampler` 是线性插值，相位用 **Q16 定点、64 位累加**：32 位在
48k→48k（step = 65536）时单块超过约 6.5 万帧就会回绕，表现为多吐 2 个
样本并读到缓冲区外（爆音）。这一点有专门的回归用例。

## 响度压缩（未做）

官方还有一层 `LoudnessAudioProcessor`（`libaudioprocessor.so` →
SAMICore → `mammon::LoudnessProcess`，参数在
`assets/boost_sound_compressor_opt.json`）。没有移植，原因：

1. 它的 `Threshold dB = 0` 假定信号已由**服务端下发的**
   `volumeBalanceSrcLoudness` 提到目标电平，我们没有那个参数；
2. 增益决策在 stripped 的 SAMICore 里，官方目标 LUFS 无法取得；
3. 直接打包官方 `.so` 不可行：`p_align=0x1000`（不满足 Android 15+
   的 16 KiB 页要求）、私有许可、连带 17 个依赖库约 +15 MB/ABI。

如果以后要响度拉平，应按 BS.1770 / EBU R128 标准实现单遍流式归一，
目标取 -16 LUFS，而不是照抄上述 JSON 参数。

## 回归

```bash
NATIVE_CC=gcc node --test test/native_atempo_test.cjs
```

覆盖时长比例、幅度稳定、440 Hz 纯音保真度（R²）、拼接处无爆音、
窗口按 `sample_rate/24` 推导、单/立体声一致；重采样部分覆盖帧数比例、
音高保持、无爆音、幅度保持与长缓冲不溢出。

## 许可

本目录是 LGPL-2.1-or-later 的衍生作品。分发二进制时必须随附本目录源码
与 LGPL 文本；不要把这个文件当作 MIT/BSD 代码使用。
