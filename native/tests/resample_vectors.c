/*
 * 重采样回归驱动（issue #129）。
 *
 * 验证变速前置的一级不改变音高与幅度：
 *   - 输出帧数 / 输入帧数 == out_rate / in_rate
 *   - 纯音频率保持不变
 *   - 没有削顶或爆音
 *
 * 用法：resample-vectors <in_rate> <out_rate> <channels> <freq> <seconds>
 */
#include "../audio_tempo/sp_resample.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double rms_of(const int16_t *x, size_t frames, int ch) {
    if (frames == 0) return 0.0;
    double sum = 0.0;
    for (size_t i = 0; i < frames * (size_t)ch; i++) {
        const double v = (double)x[i];
        sum += v * v;
    }
    return sqrt(sum / (double)(frames * (size_t)ch));
}

static double freq_of(const int16_t *x, size_t frames, int ch, int rate) {
    if (frames < 2) return 0.0;
    long crossing = 0;
    for (size_t i = 1; i < frames; i++) {
        const int16_t prev = x[(i - 1) * (size_t)ch];
        const int16_t cur = x[i * (size_t)ch];
        if ((prev <= 0 && cur > 0) || (prev >= 0 && cur < 0)) crossing++;
    }
    if (!crossing) return 0.0;
    return ((double)crossing / 2.0) / ((double)frames / (double)rate);
}

static int max_step_of(const int16_t *x, size_t frames, int ch) {
    int worst = 0;
    for (size_t i = 1; i < frames; i++) {
        int d = (int)x[i * (size_t)ch] - (int)x[(i - 1) * (size_t)ch];
        if (d < 0) d = -d;
        if (d > worst) worst = d;
    }
    return worst;
}

int main(int argc, char **argv) {
    if (argc < 6) {
        fprintf(stderr, "usage: %s <in_rate> <out_rate> <ch> <freq> <seconds>\n",
                argv[0]);
        return 2;
    }
    const int in_rate = atoi(argv[1]);
    const int out_rate = atoi(argv[2]);
    const int ch = atoi(argv[3]);
    const double freq = atof(argv[4]);
    const double seconds = atof(argv[5]);
    if (in_rate <= 0 || out_rate <= 0 || ch <= 0 || freq <= 0 || seconds <= 0) {
        fprintf(stderr, "invalid arguments\n");
        return 2;
    }

    const size_t in_frames = (size_t)(seconds * (double)in_rate);
    int16_t *in = (int16_t *)calloc(in_frames * (size_t)ch, sizeof(int16_t));
    if (!in) return 3;
    for (size_t f = 0; f < in_frames; f++) {
        const double phase =
            2.0 * M_PI * freq * (double)f / (double)in_rate;
        const int16_t v = (int16_t)(sin(phase) * 8000.0);
        for (int c = 0; c < ch; c++) in[f * (size_t)ch + (size_t)c] = v;
    }

    struct sp_resampler *r = sp_resampler_create(in_rate, out_rate, ch);
    if (!r) {
        fprintf(stderr, "resampler create failed\n");
        free(in);
        return 3;
    }
    const size_t bound = sp_resampler_output_bound(r, in_frames);
    int16_t *out = (int16_t *)calloc((bound + 8) * (size_t)ch, sizeof(int16_t));
    if (!out) {
        sp_resampler_destroy(r);
        free(in);
        return 3;
    }

    const size_t produced = sp_resampler_process(r, in, in_frames, out, bound);

    printf("in_frames=%zu\n", in_frames);
    printf("out_frames=%zu\n", produced);
    printf("ratio=%.4f\n", (double)produced / (double)in_frames);
    printf("expected_ratio=%.4f\n", (double)out_rate / (double)in_rate);
    printf("in_freq=%.2f\n", freq_of(in, in_frames, ch, in_rate));
    printf("out_freq=%.2f\n", freq_of(out, produced, ch, out_rate));
    printf("in_rms=%.1f\n", rms_of(in, in_frames, ch));
    printf("out_rms=%.1f\n", rms_of(out, produced, ch));
    printf("in_max_step=%d\n", max_step_of(in, in_frames, ch));
    printf("out_max_step=%d\n", max_step_of(out, produced, ch));

    sp_resampler_destroy(r);
    free(out);
    free(in);
    return 0;
}
