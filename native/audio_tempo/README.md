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

## 回归

```bash
NATIVE_CC=gcc node --test test/native_atempo_test.cjs
```

覆盖时长比例、幅度稳定、440 Hz 纯音保真度（R²）、拼接处无爆音、
窗口按 `sample_rate/24` 推导、单/立体声一致。

## 许可

本目录是 LGPL-2.1-or-later 的衍生作品。分发二进制时必须随附本目录源码
与 LGPL 文本；不要把这个文件当作 MIT/BSD 代码使用。
