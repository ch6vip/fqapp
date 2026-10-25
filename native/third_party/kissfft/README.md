# kissfft

`kiss_fft.c`, `kiss_fft.h`, `_kiss_fft_guts.h`, `kiss_fft_log.h`,
`kiss_fftr.c`, `kiss_fftr.h` are unmodified copies of
[mborgerding/kissfft](https://github.com/mborgerding/kissfft) at commit
`e5dc279d（master，2026-10）`. The upstream BSD-3-Clause license is
preserved in [COPYING](COPYING).

用途：`native/audio_tempo/sp_atempo.c`（FFmpeg `af_atempo` 的移植，issue #129）
需要一对实数 FFT（rDFT）。上游用 `libavutil` 的 `av_tx`，这里用 kissfft 的
`kiss_fftr` / `kiss_fftri` 替代，避免为了一个滤镜拖进整个 FFmpeg。

注意：`kiss_fftri` 内部会除以 nfft，而上游 `av_tx_init` 在 atempo 里传入的
`iscale` 是 1.0（不归一化）。`sp_atempo.c` 在互相关之后乘回 nfft 抹平这个
差异，改动那一处时必须一起看。

构建时 `kiss_fft.c` 自带一处 `-Wsign-compare`，属于上游代码，本项目只对它
放宽该告警（见 `native/CMakeLists.txt`）。
