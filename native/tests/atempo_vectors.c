/*
 * sp_atempo 的宿主机测试驱动。
 *
 * 覆盖三件事：
 *   1. 时长正确性：N 个输入样本在 tempo 下应产出约 N/tempo 个输出样本；
 *   2. 信号连续性：纯音输入经变速后仍能测出同一个基频（没有断帧/爆音）；
 *   3. 幅度稳定：输出 RMS 与输入接近（WSOLA 的重叠相加不能放大或衰减）。
 *
 * 用法（由 test/native_atempo_test.cjs 调用）：
 *   atempo-vectors <sample_rate> <channels> <tempo> <freq_hz> <seconds>
 * 逐行输出 key=value，供 Node 侧断言。
 */
#include "../audio_tempo/sp_atempo.h"

#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK_FRAMES 4096
#define MAX_OUTPUT_SECONDS 120

static double compute_rms(const int16_t *samples, size_t count) {
    if (count == 0) return 0.0;
    double sum = 0.0;
    for (size_t i = 0; i < count; i++) {
        const double v = (double)samples[i];
        sum += v * v;
    }
    return sqrt(sum / (double)count);
}

/*
 * 过零率估基频（只对单声道纯音可靠，够这里用）。
 * 返回 0 表示样本太少。
 */
static double estimate_freq(const int16_t *samples, size_t frames, int channels,
                            int sample_rate) {
    if (frames < 2) return 0.0;
    long crossings = 0;
    size_t i;
    for (i = 1; i < frames; i++) {
        const int16_t prev = samples[(i - 1) * channels];
        const int16_t cur = samples[i * channels];
        if ((prev <= 0 && cur > 0) || (prev >= 0 && cur < 0)) crossings++;
    }
    if (crossings == 0) return 0.0;
    const double seconds = (double)frames / (double)sample_rate;
    return ((double)crossings / 2.0) / seconds;
}

/* 找出信号中点的最大样本跳变，用于发现拼接处的爆音。 */
static int max_step(const int16_t *samples, size_t frames, int channels) {
    int worst = 0;
    for (size_t i = 1; i < frames; i++) {
        int d = (int)samples[i * channels] - (int)samples[(i - 1) * channels];
        if (d < 0) d = -d;
        if (d > worst) worst = d;
    }
    return worst;
}

int main(int argc, char **argv) {
    if (argc < 6) {
        fprintf(stderr,
                "usage: %s <sample_rate> <channels> <tempo> <freq_hz> <seconds>\n",
                argv[0]);
        return 2;
    }

    const int sample_rate = atoi(argv[1]);
    const int channels = atoi(argv[2]);
    const double tempo = atof(argv[3]);
    const double freq = atof(argv[4]);
    const double seconds = atof(argv[5]);

    if (sample_rate <= 0 || channels <= 0 || tempo <= 0 || freq <= 0 ||
        seconds <= 0) {
        fprintf(stderr, "invalid arguments\n");
        return 2;
    }

    const size_t input_frames = (size_t)(seconds * sample_rate);
    const size_t input_samples = input_frames * (size_t)channels;
    int16_t *input = (int16_t *)calloc(input_samples, sizeof(int16_t));
    if (!input) {
        fprintf(stderr, "oom\n");
        return 3;
    }

    /* 1 kHz 量级纯音，幅度 8000（不削顶）。 */
    for (size_t f = 0; f < input_frames; f++) {
        const double phase = 2.0 * M_PI * freq * (double)f / (double)sample_rate;
        const int16_t v = (int16_t)(sin(phase) * 8000.0);
        for (int c = 0; c < channels; c++) {
            input[f * (size_t)channels + (size_t)c] = v;
        }
    }

    struct sp_atempo *h = sp_atempo_create(sample_rate, channels, tempo);
    if (!h) {
        fprintf(stderr, "sp_atempo_create failed\n");
        free(input);
        return 3;
    }

    const size_t out_capacity_samples =
        64u * 1024u * (size_t)channels;
    int16_t *out = (int16_t *)calloc(out_capacity_samples, sizeof(int16_t));
    if (!out) {
        fprintf(stderr, "oom\n");
        sp_atempo_destroy(h);
        free(input);
        return 3;
    }

    int16_t *collected = (int16_t *)calloc(
        (size_t)MAX_OUTPUT_SECONDS * (size_t)sample_rate * (size_t)channels,
        sizeof(int16_t));
    if (!collected) {
        fprintf(stderr, "oom\n");
        free(out);
        sp_atempo_destroy(h);
        free(input);
        return 3;
    }
    size_t collected_samples = 0;
    const size_t collected_capacity =
        (size_t)MAX_OUTPUT_SECONDS * (size_t)sample_rate * (size_t)channels;

    /* 分块喂入，模拟 ExoPlayer 的 AudioProcessor 调用节奏。 */
    size_t offset = 0;
    const size_t block_samples = (size_t)BLOCK_FRAMES * (size_t)channels;
    while (offset < input_samples) {
        const size_t remain = input_samples - offset;
        const size_t this_block = remain < block_samples ? remain : block_samples;
        size_t used = 0, written = 0;
        const int rc = sp_atempo_process(h, input + offset, this_block * sizeof(int16_t),
                                         out, out_capacity_samples * sizeof(int16_t),
                                         &used, &written);
        if (rc != 0) {
            fprintf(stderr, "process failed rc=%d\n", rc);
            free(collected);
            free(out);
            sp_atempo_destroy(h);
            free(input);
            return 4;
        }
        offset += used / sizeof(int16_t);
        const size_t produced = written / sizeof(int16_t);
        if (collected_samples + produced <= collected_capacity) {
            memcpy(collected + collected_samples, out, written);
            collected_samples += produced;
        }
        if (used == 0 && written == 0) break; /* 还需要更多输入，正常退出循环 */
    }

    /* 冲出尾部残留。 */
    for (int guard = 0; guard < 10000; guard++) {
        size_t written = 0;
        if (sp_atempo_flush(h, out, out_capacity_samples * sizeof(int16_t),
                            &written) != 0) {
            break;
        }
        if (written == 0) break;
        const size_t produced = written / sizeof(int16_t);
        if (collected_samples + produced > collected_capacity) break;
        memcpy(collected + collected_samples, out, written);
        collected_samples += produced;
    }

    const size_t out_frames = collected_samples / (size_t)channels;
    const double expected_frames = (double)input_frames / tempo;
    const double ratio = expected_frames > 0
                             ? (double)out_frames / expected_frames
                             : 0.0;

    /* 只测中间 60%（跳过起始/收尾的淡入淡出与补零）。 */
    const size_t mid_start = out_frames / 5;
    const size_t mid_frames = out_frames / 2;
    const int mid_channels = channels;
    const int16_t *mid = collected + mid_start * (size_t)mid_channels;

    int window = 0;
    int64_t in_pos = 0, out_pos = 0;
    sp_atempo_debug_state(h, &window, &in_pos, &out_pos);

    printf("input_frames=%zu\n", input_frames);
    printf("output_frames=%zu\n", out_frames);
    printf("expected_frames=%.1f\n", expected_frames);
    printf("duration_ratio=%.4f\n", ratio);
    printf("window=%d\n", window);
    printf("input_rms=%.1f\n", compute_rms(input, input_samples));
    printf("output_rms=%.1f\n", compute_rms(mid, mid_frames * (size_t)mid_channels));
    printf("output_freq=%.2f\n", estimate_freq(mid, mid_frames, channels, sample_rate));

    /* 纯音保真度：把输出中段与同频理想正弦做二元线性回归（y ~ a*sin + b*cos），
     * R^2 接近 1 表示波形没被破坏（WSOLA 拼接点没错位）。 */
    {
        double sum_s = 0.0, sum_c = 0.0, sum_y = 0.0, sum_ss = 0.0;
        double sum_cc = 0.0, sum_yy = 0.0, sum_sc = 0.0, sum_sy = 0.0;
        double sum_cy = 0.0;
        for (size_t f = 0; f < mid_frames; f++) {
            const double ph = 2.0 * M_PI * freq * (double)f / (double)sample_rate;
            const double sv = sin(ph), cv = cos(ph);
            const double yv = (double)mid[f * (size_t)channels];
            sum_s += sv; sum_c += cv; sum_y += yv;
            sum_ss += sv * sv; sum_cc += cv * cv; sum_yy += yv * yv;
            sum_sc += sv * cv; sum_sy += sv * yv; sum_cy += cv * yv;
        }
        const double n = (double)mid_frames;
        const double var_y = sum_yy - sum_y * sum_y / n;
        const double var_s = sum_ss - sum_s * sum_s / n;
        const double var_c = sum_cc - sum_c * sum_c / n;
        const double cov_sy = sum_sy - sum_s * sum_y / n;
        const double cov_cy = sum_cy - sum_c * sum_y / n;
        const double cov_sc = sum_sc - sum_s * sum_c / n;
        const double det = var_s * var_c - cov_sc * cov_sc;
        if (det > 1e-9 && var_y > 1e-9) {
            const double a = (cov_sy * var_c - cov_cy * cov_sc) / det;
            const double b = (cov_cy * var_s - cov_sy * cov_sc) / det;
            printf("tone_r2=%.4f\n", (a * cov_sy + b * cov_cy) / var_y);
        } else {
            printf("tone_r2=0.0000\n");
        }
    }
    printf("output_max_step=%d\n",
           max_step(collected, out_frames, channels));
    printf("input_max_step=%d\n", max_step(input, input_frames, channels));

    free(collected);
    free(out);
    sp_atempo_destroy(h);
    free(input);
    return 0;
}
