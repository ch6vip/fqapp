/*
 * WSOLA 时伸缩：FFmpeg libavfilter/af_atempo.c 的精简移植。
 *
 * 算法本体逐字来自 FFmpeg 7.1 的 libavfilter/af_atempo.c
 * （Copyright (c) 2012 Pavel Koshevoy，LGPL-2.1-or-later），
 * 只把三处框架依赖换成本项目的实现：
 *
 *   1. AVFilterContext / AVFrame 管线  -> 一个直接的 push/pull 接口
 *   2. av_tx_init(AV_TX_FLOAT_RDFT)    -> kissfft 的 kiss_fftr
 *   3. av_calloc / av_log2 / FFMIN     -> libc + 本地宏
 *
 * 为什么是这一份，而不是自己写：番茄 7.0.9.32 的听书倍速就是这条路
 * （libttmplayer.so 里 avfilter_get_by_name("atempo")、参数 "tempo=%1.2f"、
 * aformat -> atempo -> abuffersink），见 issue #129。要让听感与官方一致，
 * 就必须用同一套 WSOLA 参数（window = sample_rate / 24、Hann 窗、
 * 归一化互相关对齐、tempo > 2 时级联）。
 *
 * 与官方唯一的差别是采样格式：这里只保留 S16（ExoPlayer 交给
 * AudioProcessor 的永远是 16-bit PCM），其它格式的 yae_blend/yae_downmix
 * 分支原样留着，便于以后接 float 管线。
 *
 * 许可：本文件是 LGPL-2.1-or-later 的衍生作品，随附 COPYING.LGPL-2.1。
 * 修改请保留本头注释与上游版权声明。
 */

#include "sp_atempo.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "kiss_fftr.h"

/* C11 不保证 M_PI（严格 -std=c11 下 math.h 不导出），自己兜住。 */
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifndef FFMIN
#define FFMIN(a, b) ((a) > (b) ? (b) : (a))
#endif
#ifndef FFMAX
#define FFMAX(a, b) ((a) > (b) ? (a) : (b))
#endif

/* 上游 YAE_ATEMPO_MIN / MAX：超出范围直接拒绝，与官方一致。 */
#define YAE_ATEMPO_MIN 0.5
#define YAE_ATEMPO_MAX 100.0

typedef struct AudioFragment {
    /* original packed multi-channel samples: */
    uint8_t *data;
    /* number of samples in this fragment: */
    int nsamples;
    /* rDFT transform of the down-mixed mono fragment, used for
     * fast waveform alignment via correlation in frequency domain: */
    float *xdat_in;
    float *xdat;
    int64_t position[2];
} AudioFragment;

typedef enum {
    YAE_LOAD_FRAGMENT,
    YAE_ADJUST_POSITION,
    YAE_RELOAD_FRAGMENT,
    YAE_OUTPUT_OVERLAP_ADD,
    YAE_FLUSH_OUTPUT,
} FilterState;

struct sp_atempo {
    /* ring-buffer of input samples, necessary because some times
     * input fragment position may be adjusted backwards: */
    uint8_t *buffer;
    /* ring-buffer maximum capacity, expressed in sample rate time base: */
    int ring;
    /* ring-buffer house keeping: */
    int size;
    int head;
    int tail;
    /* 0: input sample position corresponding to the ring buffer tail
     * 1: output sample position */
    int64_t position[2];
    /* sample format: 只实现 S16，见文件头说明 */
    int stride;
    int channels;
    /* fragment window size, power-of-two integer: */
    int window;
    /* Hann window coefficients, for feathering
     * (blending) the overlapping fragment region: */
    float *hann;
    /* tempo scaling factor: */
    double tempo;
    /* a snapshot of previous fragment input and output position values
     * captured when the tempo scale factor was set most recently: */
    int64_t origin[2];
    /* current/previous fragment ring-buffer: */
    AudioFragment frag[2];
    /* current fragment index: */
    uint64_t nfrag;
    /* current state: */
    FilterState state;
    /* for fast correlation calculation in frequency domain: */
    kiss_fftr_cfg fft_fwd;
    kiss_fftr_cfg fft_inv;
    int fft_nfft;
    float *correlation_in;
    float *correlation;
    /* flush 时暂存输出的目标缓冲（等价上游的 dst_buffer/AVFrame） */
    int64_t nsamples_out;
};

static AudioFragment *yae_curr_frag(struct sp_atempo *atempo)
{
    return &atempo->frag[atempo->nfrag % 2];
}

static AudioFragment *yae_prev_frag(struct sp_atempo *atempo)
{
    return &atempo->frag[(atempo->nfrag + 1) % 2];
}

static void yae_release_buffers(struct sp_atempo *atempo)
{
    if (atempo->fft_fwd) {
        kiss_fftr_free(atempo->fft_fwd);
        atempo->fft_fwd = NULL;
    }
    if (atempo->fft_inv) {
        kiss_fftr_free(atempo->fft_inv);
        atempo->fft_inv = NULL;
    }
    for (int i = 0; i < 2; i++) {
        free(atempo->frag[i].data);
        free(atempo->frag[i].xdat_in);
        free(atempo->frag[i].xdat);
        atempo->frag[i].data = NULL;
        atempo->frag[i].xdat_in = NULL;
        atempo->frag[i].xdat = NULL;
    }
    free(atempo->correlation_in);
    free(atempo->correlation);
    free(atempo->buffer);
    free(atempo->hann);
    atempo->correlation_in = NULL;
    atempo->correlation = NULL;
    atempo->buffer = NULL;
    atempo->hann = NULL;
}

static void yae_clear(struct sp_atempo *atempo)
{
    atempo->size = 0;
    atempo->head = 0;
    atempo->tail = 0;

    atempo->nfrag = 0;
    atempo->state = YAE_LOAD_FRAGMENT;

    atempo->position[0] = 0;
    atempo->position[1] = 0;

    atempo->origin[0] = 0;
    atempo->origin[1] = 0;

    for (int i = 0; i < 2; i++) {
        atempo->frag[i].position[0] = 0;
        atempo->frag[i].position[1] = 0;
        atempo->frag[i].nsamples = 0;
    }

    /* shift left position of 1st fragment by half a window */
    atempo->frag[0].position[0] = -(int64_t)(atempo->window / 2);
    atempo->frag[0].position[1] = -(int64_t)(atempo->window / 2);
}

/*
 * Reset filter to the given parameters. 窗口推导与上游 yae_reset 完全一致：
 * window = sample_rate / 24 再向上取到 2 的幂。
 */
static int yae_reset(struct sp_atempo *atempo, int sample_rate, int channels)
{
    uint32_t nlevels = 0;
    uint32_t pot;
    int i;
    int ret = 0;

    atempo->channels = channels;
    atempo->stride = (int)sizeof(int16_t) * channels;

    /* pick a segment window size: */
    atempo->window = sample_rate / 24;

    /* adjust window size to be a power-of-two integer: */
    nlevels = 0;
    pot = 1;
    while (pot < (uint32_t)atempo->window) {
        pot <<= 1;
        nlevels++;
    }
    if (pot > (uint32_t)atempo->window) {
        /* 上游这里用 av_log2 取 floor，再在 2^floor < window 时乘 2：
         * floor 的 2 的幂，若严格小于 window 则取 2*2^floor，
         * 等价于 ceil 到 2 的幂。下面按同一规则重写，避免依赖 av_log2。 */
        uint32_t floor_pot = pot >> 1;
        nlevels -= 1;
        if (floor_pot < (uint32_t)atempo->window) {
            pot = floor_pot * 2;
            nlevels += 1;
        } else {
            pot = floor_pot;
        }
    }
    atempo->window = (int)pot;

    yae_release_buffers(atempo);

    for (i = 0; i < 2; i++) {
        atempo->frag[i].data = (uint8_t *)calloc(
            (size_t)atempo->window, (size_t)atempo->stride);
        atempo->frag[i].xdat_in = (float *)calloc(
            (size_t)atempo->window + 1, sizeof(float) * 2);
        atempo->frag[i].xdat = (float *)calloc(
            (size_t)atempo->window + 1, sizeof(float) * 2);
        if (!atempo->frag[i].data || !atempo->frag[i].xdat_in ||
            !atempo->frag[i].xdat) {
            ret = -1;
            goto fail;
        }
    }

    /* initialize rDFT contexts：上游取 2^（nlevels+1）点实数变换 */
    atempo->fft_nfft = (int)(1u << (nlevels + 1));
    atempo->fft_fwd = kiss_fftr_alloc(atempo->fft_nfft, 0, NULL, NULL);
    atempo->fft_inv = kiss_fftr_alloc(atempo->fft_nfft, 1, NULL, NULL);
    if (!atempo->fft_fwd || !atempo->fft_inv) {
        ret = -1;
        goto fail;
    }

    /* 上游用 sizeof(AVComplexFloat) 分配：逆 rDFT 会写满 2*window 个 float，
     * 按 float 分配只有一半，必然越界。 */
    atempo->correlation_in = (float *)calloc(
        (size_t)atempo->window + 1, sizeof(float) * 2);
    atempo->correlation = (float *)calloc(
        (size_t)atempo->window, sizeof(float) * 2);

    atempo->ring = atempo->window * 3;
    atempo->buffer = (uint8_t *)calloc(
        (size_t)atempo->ring, (size_t)atempo->stride);
    atempo->hann = (float *)calloc((size_t)atempo->window, sizeof(float));

    if (!atempo->correlation_in || !atempo->correlation || !atempo->buffer ||
        !atempo->hann) {
        ret = -1;
        goto fail;
    }

    /* initialize the Hann window function: */
    for (i = 0; i < atempo->window; i++) {
        double t = (double)i / (double)(atempo->window - 1);
        double h = 0.5 * (1.0 - cos(2.0 * M_PI * t));
        atempo->hann[i] = (float)h;
    }

    yae_clear(atempo);
    return 0;

fail:
    yae_release_buffers(atempo);
    return ret;
}

static void yae_update(struct sp_atempo *atempo)
{
    const AudioFragment *prev = yae_prev_frag(atempo);
    atempo->origin[0] = prev->position[0] + atempo->window / 2;
    atempo->origin[1] = prev->position[1] + atempo->window / 2;
}

/* 单声道下混。上游支持 U8/S16/S32/FLT/DBL，这里只保留 S16 并按原样写。 */
static void yae_downmix(struct sp_atempo *atempo, AudioFragment *frag)
{
    const uint8_t *src = frag->data;
    const uint8_t *src_end =
        src + frag->nsamples * atempo->channels * sizeof(int16_t);
    float *xdat = frag->xdat_in;

    memset(frag->xdat_in, 0, sizeof(float) * 2 * ((size_t)atempo->window + 1));

    if (atempo->channels == 1) {
        for (; src < src_end; xdat++) {
            int16_t tmp = *(const int16_t *)src;
            src += sizeof(int16_t);
            *xdat = (float)tmp;
        }
    } else {
        /* 多声道取绝对值最大的那个声道（上游 yae_init_xdat 的规则） */
        for (; src < src_end; xdat++) {
            int16_t tmp = *(const int16_t *)src;
            src += sizeof(int16_t);

            float max = (float)tmp;
            float s = FFMIN((float)32767, (float)fabsf(max));

            for (int i = 1; i < atempo->channels; i++) {
                tmp = *(const int16_t *)src;
                src += sizeof(int16_t);

                float ti = (float)tmp;
                float si = FFMIN((float)32767, (float)fabsf(ti));

                if (s < si) {
                    s = si;
                    max = ti;
                }
            }
            *xdat = max;
        }
    }
}

static int yae_load_data(struct sp_atempo *atempo,
                         const uint8_t **src_ref,
                         const uint8_t *src_end,
                         int64_t stop_here)
{
    const uint8_t *src = *src_ref;
    const int read_size = (int)(stop_here - atempo->position[0]);

    if (stop_here <= atempo->position[0]) {
        return 0;
    }

    /* samples are not expected to be skipped, unless tempo is greater than 2: */
    if (!(read_size <= atempo->ring || atempo->tempo > 2.0)) {
        return -2;
    }

    while (atempo->position[0] < stop_here && src < src_end) {
        int src_samples = (int)((src_end - src) / atempo->stride);

        int nsamples = FFMIN(read_size, src_samples);
        int na;
        int nb;

        nsamples = FFMIN(nsamples, atempo->ring);
        na = FFMIN(nsamples, atempo->ring - atempo->tail);
        nb = FFMIN(nsamples - na, atempo->ring);

        if (na) {
            uint8_t *a = atempo->buffer + atempo->tail * atempo->stride;
            memcpy(a, src, (size_t)na * (size_t)atempo->stride);

            src += na * atempo->stride;
            atempo->position[0] += na;

            atempo->size = FFMIN(atempo->size + na, atempo->ring);
            atempo->tail = (atempo->tail + na) % atempo->ring;
            atempo->head = atempo->size < atempo->ring ? atempo->tail - atempo->size
                                                       : atempo->tail;
        }

        if (nb) {
            uint8_t *b = atempo->buffer;
            memcpy(b, src, (size_t)nb * (size_t)atempo->stride);

            src += nb * atempo->stride;
            atempo->position[0] += nb;

            atempo->size = FFMIN(atempo->size + nb, atempo->ring);
            atempo->tail = (atempo->tail + nb) % atempo->ring;
            atempo->head = atempo->size < atempo->ring ? atempo->tail - atempo->size
                                                       : atempo->tail;
        }
    }

    *src_ref = src;

    return atempo->position[0] == stop_here ? 0 : -3;
}

static int yae_load_frag(struct sp_atempo *atempo,
                         const uint8_t **src_ref,
                         const uint8_t *src_end)
{
    AudioFragment *frag = yae_curr_frag(atempo);
    uint8_t *dst;
    int64_t missing, start, zeros;
    uint32_t nsamples;
    const uint8_t *a, *b;
    int i0, i1, n0, n1, na, nb;

    int64_t stop_here = frag->position[0] + atempo->window;
    if (src_ref && yae_load_data(atempo, src_ref, src_end, stop_here) != 0) {
        return -3;
    }

    missing = stop_here > atempo->position[0] ? stop_here - atempo->position[0] : 0;

    nsamples = missing < (int64_t)atempo->window
                   ? (uint32_t)(atempo->window - missing)
                   : 0;

    frag->nsamples = (int)nsamples;
    dst = frag->data;

    start = atempo->position[0] - atempo->size;

    zeros = frag->position[0] < start
                ? FFMIN(start - frag->position[0], (int64_t)nsamples)
                : 0;

    if (zeros == (int64_t)nsamples) {
        return 0;
    }

    if (frag->position[0] < start) {
        memset(dst, 0, (size_t)zeros * (size_t)atempo->stride);
        dst += zeros * atempo->stride;
    }

    na = (atempo->head < atempo->tail ? atempo->tail - atempo->head
                                      : atempo->ring - atempo->head);

    nb = atempo->head < atempo->tail ? 0 : atempo->tail;

    if (!((int64_t)nsamples <= zeros + na + nb)) {
        return -4;
    }

    a = atempo->buffer + atempo->head * atempo->stride;
    b = atempo->buffer;

    i0 = (int)(frag->position[0] + zeros - start);
    i1 = i0 < na ? 0 : i0 - na;

    n0 = i0 < na ? FFMIN(na - i0, (int)(nsamples - zeros)) : 0;
    n1 = (int)nsamples - (int)zeros - n0;

    if (n0) {
        memcpy(dst, a + i0 * atempo->stride, (size_t)n0 * (size_t)atempo->stride);
        dst += n0 * atempo->stride;
    }

    if (n1) {
        memcpy(dst, b + i1 * atempo->stride, (size_t)n1 * (size_t)atempo->stride);
    }

    return 0;
}

static void yae_advance_to_next_frag(struct sp_atempo *atempo)
{
    const double fragment_step = atempo->tempo * (double)(atempo->window / 2);

    atempo->nfrag++;
    const AudioFragment *prev = yae_prev_frag(atempo);
    AudioFragment *frag = yae_curr_frag(atempo);

    frag->position[0] = prev->position[0] + (int64_t)fragment_step;
    frag->position[1] = prev->position[1] + atempo->window / 2;
    frag->nsamples = 0;
}

/*
 * Cross-correlation via rDFT：两个实信号的互相关 = 各自 rDFT 的共轭相乘，
 * 再做逆 rDFT。上游用 av_tx 复数数组，这里用 kissfft 的 float 交错数组。
 */
static void yae_xcorr_via_rdft(float *xcorr_in,
                               float *xcorr,
                               kiss_fftr_cfg c2r,
                               const float *xa,
                               const float *xb,
                               const int window,
                               const int nfft)
{
    const int bins = window / 2 + 1;
    for (int i = 0; i < bins; i++) {
        const float are = xa[2 * i], aim = xa[2 * i + 1];
        const float bre = xb[2 * i], bim = xb[2 * i + 1];
        /* xa * conj(xb) 的实部/虚部 */
        xcorr_in[2 * i] = are * bre + aim * bim;
        xcorr_in[2 * i + 1] = aim * bre - are * bim;
    }

    /*
     * 与上游的缩放对齐：atempo 里 av_tx_init 的正/逆变换 scale 都是 1.0f，
     * 也就是**不归一化**；kissfft 的 kiss_fftri 内部会除以 nfft。
     * 这里把 nfft 乘回去，让互相关的幅度与上游逐值一致——否则整个相关序列
     * 会缩小 nfft 倍，yae_align 里 `metric > best_metric`（初值 -FLT_MAX）
     * 的比较虽然仍能选出最大值，但归一化项 `drifti*(i-i0)*(i1-i)` 的量级
     * 与相关值不再匹配，搜索窗内会被权重项主导，选错对齐点。
     */
    kiss_fftri(c2r, (const kiss_fft_cpx *)xcorr_in, xcorr);

    for (int i = 0; i < window; i++) {
        xcorr[i] *= (float)nfft;
    }
}

static int yae_align(AudioFragment *frag,
                     const AudioFragment *prev,
                     const int window,
                     const int delta_max,
                     const int drift,
                     float *correlation_in,
                     float *correlation,
                     kiss_fftr_cfg c2r,
                     const int nfft)
{
    int best_offset = -drift;
    float best_metric = -FLT_MAX;
    float *xcorr;

    int i0;
    int i1;
    int i;

    yae_xcorr_via_rdft(correlation_in, correlation, c2r, prev->xdat,
                       frag->xdat, window, nfft);

    /* identify search window boundaries: */
    i0 = FFMAX(window / 2 - delta_max - drift, 0);
    i0 = FFMIN(i0, window);

    i1 = FFMIN(window / 2 + delta_max - drift, window - window / 16);
    i1 = FFMAX(i1, 0);

    /* identify cross-correlation peaks within search window: */
    xcorr = correlation + i0;

    for (i = i0; i < i1; i++, xcorr++) {
        float metric = *xcorr;

        /* normalize: */
        float drifti = (float)(drift + i);
        metric *= drifti * (float)(i - i0) * (float)(i1 - i);

        if (metric > best_metric) {
            best_metric = metric;
            best_offset = i - window / 2;
        }
    }

    return best_offset;
}

static int yae_adjust_position(struct sp_atempo *atempo)
{
    const AudioFragment *prev = yae_prev_frag(atempo);
    AudioFragment *frag = yae_curr_frag(atempo);

    const double prev_output_position =
        (double)(prev->position[1] - atempo->origin[1] + atempo->window / 2) *
        atempo->tempo;

    const double ideal_output_position =
        (double)(prev->position[0] - atempo->origin[0] + atempo->window / 2);

    const int drift = (int)(prev_output_position - ideal_output_position);

    const int delta_max = atempo->window / 2;
    const int correction = yae_align(frag, prev, atempo->window, delta_max,
                                     drift, atempo->correlation_in,
                                     atempo->correlation, atempo->fft_inv,
                                     atempo->fft_nfft);

    if (correction) {
        frag->position[0] -= correction;
        frag->nsamples = 0;
    }

    return correction;
}

/* 重叠相加，只保留 S16（上游模板覆盖 5 种格式）。 */
static int yae_overlap_add(struct sp_atempo *atempo,
                           uint8_t **dst_ref,
                           uint8_t *dst_end)
{
    const AudioFragment *prev = yae_prev_frag(atempo);
    const AudioFragment *frag = yae_curr_frag(atempo);

    const int64_t start_here = FFMAX(atempo->position[1], frag->position[1]);

    const int64_t stop_here =
        FFMIN(prev->position[1] + prev->nsamples,
              frag->position[1] + frag->nsamples);

    const int64_t overlap = stop_here - start_here;

    const int64_t ia = start_here - prev->position[1];
    const int64_t ib = start_here - frag->position[1];

    const float *wa = atempo->hann + ia;
    const float *wb = atempo->hann + ib;

    const uint8_t *a = prev->data + ia * atempo->stride;
    const uint8_t *b = frag->data + ib * atempo->stride;

    uint8_t *dst = *dst_ref;

    if (!(start_here <= stop_here && frag->position[1] <= start_here &&
          overlap <= frag->nsamples)) {
        return -5;
    }

    const int16_t *aaa = (const int16_t *)a;
    const int16_t *bbb = (const int16_t *)b;
    int16_t *out = (int16_t *)dst;
    int16_t *out_end = (int16_t *)dst_end;
    int64_t i;

    for (i = 0; i < overlap && out < out_end;
         i++, atempo->position[1]++, wa++, wb++) {
        float w0 = *wa;
        float w1 = *wb;
        for (int j = 0; j < atempo->channels; j++, aaa++, bbb++, out++) {
            float t0 = (float)*aaa;
            float t1 = (float)*bbb;

            *out = frag->position[0] + i < 0 ? *aaa
                                             : (int16_t)(t0 * w0 + t1 * w1);
        }
    }
    dst = (uint8_t *)out;

    *dst_ref = dst;

    return atempo->position[1] == stop_here ? 0 : -3;
}

static void yae_apply(struct sp_atempo *atempo,
                      const uint8_t **src_ref,
                      const uint8_t *src_end,
                      uint8_t **dst_ref,
                      uint8_t *dst_end)
{
    /*
     * flush 之后若又有新输入（seek / 循环播放），状态机必须回到正常流程，
     * 否则 yae_apply 的四个分支全都不匹配，永远不产帧——表现为 seek 之后
     * 静默无声。位置与环形缓冲也要一并复位，否则新数据会接着旧时间线走。
     */
    if (atempo->state == YAE_FLUSH_OUTPUT) {
        yae_clear(atempo);
        yae_update(atempo);
    }

    while (1) {
        if (atempo->state == YAE_LOAD_FRAGMENT) {
            if (yae_load_frag(atempo, src_ref, src_end) != 0) {
                break;
            }

            yae_downmix(atempo, yae_curr_frag(atempo));

            /* 上游 r2c_fn(out=xdat, in=xdat_in)：时域在 xdat_in，频域在 xdat */
            kiss_fftr(atempo->fft_fwd,
                      (const kiss_fft_scalar *)yae_curr_frag(atempo)->xdat_in,
                      (kiss_fft_cpx *)yae_curr_frag(atempo)->xdat);

            /* must load the second fragment before alignment can start: */
            if (!atempo->nfrag) {
                yae_advance_to_next_frag(atempo);
                continue;
            }

            atempo->state = YAE_ADJUST_POSITION;
        }

        if (atempo->state == YAE_ADJUST_POSITION) {
            if (yae_adjust_position(atempo)) {
                atempo->state = YAE_RELOAD_FRAGMENT;
            } else {
                atempo->state = YAE_OUTPUT_OVERLAP_ADD;
            }
        }

        if (atempo->state == YAE_RELOAD_FRAGMENT) {
            if (yae_load_frag(atempo, src_ref, src_end) != 0) {
                break;
            }

            yae_downmix(atempo, yae_curr_frag(atempo));

            /* 上游 r2c_fn(out=xdat, in=xdat_in)：时域在 xdat_in，频域在 xdat */
            kiss_fftr(atempo->fft_fwd,
                      (const kiss_fft_scalar *)yae_curr_frag(atempo)->xdat_in,
                      (kiss_fft_cpx *)yae_curr_frag(atempo)->xdat);

            atempo->state = YAE_OUTPUT_OVERLAP_ADD;
        }

        if (atempo->state == YAE_OUTPUT_OVERLAP_ADD) {
            if (yae_overlap_add(atempo, dst_ref, dst_end) != 0) {
                break;
            }

            yae_advance_to_next_frag(atempo);
            atempo->state = YAE_LOAD_FRAGMENT;
        }
    }
}

static int yae_flush(struct sp_atempo *atempo,
                     uint8_t **dst_ref,
                     uint8_t *dst_end)
{
    AudioFragment *frag = yae_curr_frag(atempo);
    int64_t overlap_end;
    int64_t start_here;
    int64_t stop_here;
    int64_t offset;

    const uint8_t *src;
    uint8_t *dst;

    int src_size;
    int dst_size;
    int nbytes;

    atempo->state = YAE_FLUSH_OUTPUT;

    if (!atempo->nfrag) {
        return 0;
    }

    if (atempo->position[0] == frag->position[0] + frag->nsamples &&
        atempo->position[1] == frag->position[1] + frag->nsamples) {
        return 0;
    }

    if (frag->position[0] + frag->nsamples < atempo->position[0]) {
        yae_load_frag(atempo, NULL, NULL);

        if (atempo->nfrag) {
            yae_downmix(atempo, frag);

            kiss_fftr(atempo->fft_fwd, (const kiss_fft_scalar *)frag->xdat_in,
                      (kiss_fft_cpx *)frag->xdat);

            if (yae_adjust_position(atempo)) {
                yae_load_frag(atempo, NULL, NULL);
            }
        }
    }

    overlap_end = frag->position[1] + FFMIN(atempo->window / 2, frag->nsamples);

    while (atempo->position[1] < overlap_end) {
        if (yae_overlap_add(atempo, dst_ref, dst_end) != 0) {
            return -3;
        }
    }

    if (frag->position[0] + frag->nsamples < atempo->position[0]) {
        yae_advance_to_next_frag(atempo);
        return -3;
    }

    start_here = FFMAX(atempo->position[1], overlap_end);
    stop_here = frag->position[1] + frag->nsamples;
    offset = start_here - frag->position[1];
    if (!(start_here <= stop_here && frag->position[1] <= start_here)) {
        return -6;
    }

    src = frag->data + offset * atempo->stride;
    dst = (uint8_t *)*dst_ref;

    src_size = (int)(stop_here - start_here) * atempo->stride;
    dst_size = (int)(dst_end - dst);
    nbytes = FFMIN(src_size, dst_size);

    memcpy(dst, src, (size_t)nbytes);
    dst += nbytes;

    atempo->position[1] += (nbytes / atempo->stride);

    *dst_ref = (uint8_t *)dst;

    return atempo->position[1] == stop_here ? 0 : -3;
}

/* ───────────────────────── 对外接口 ───────────────────────── */

struct sp_atempo *sp_atempo_create(int sample_rate, int channels, double tempo)
{
    if (sample_rate <= 0 || channels <= 0) return NULL;
    if (!(tempo >= YAE_ATEMPO_MIN && tempo <= YAE_ATEMPO_MAX)) return NULL;

    struct sp_atempo *atempo = (struct sp_atempo *)calloc(1, sizeof(*atempo));
    if (!atempo) return NULL;

    atempo->tempo = tempo;
    atempo->state = YAE_LOAD_FRAGMENT;
    if (yae_reset(atempo, sample_rate, channels) != 0) {
        free(atempo);
        return NULL;
    }
    yae_update(atempo);
    return atempo;
}

void sp_atempo_destroy(struct sp_atempo *atempo)
{
    if (!atempo) return;
    yae_release_buffers(atempo);
    free(atempo);
}

/*
 * 上游把 tempo 变更记在 origin 快照里，下一次 yae_apply 生效。
 * 这里保持同样语义。
 */
int sp_atempo_set_tempo(struct sp_atempo *atempo, double tempo)
{
    if (!atempo) return -1;
    if (!(tempo >= YAE_ATEMPO_MIN && tempo <= YAE_ATEMPO_MAX)) return -1;
    if (atempo->tempo == tempo) return 0;
    atempo->tempo = tempo;
    yae_update(atempo);
    return 0;
}

double sp_atempo_get_tempo(const struct sp_atempo *atempo)
{
    return atempo ? atempo->tempo : 1.0;
}

int sp_atempo_process(struct sp_atempo *atempo,
                      const void *src,
                      size_t src_bytes,
                      void *dst,
                      size_t dst_capacity,
                      size_t *src_consumed,
                      size_t *dst_written)
{
    if (!atempo || !src_consumed || !dst_written) return -1;

    const uint8_t *src_ref = (const uint8_t *)src;
    const uint8_t *src_end = src_ref + src_bytes;
    uint8_t *dst_ref = (uint8_t *)dst;
    uint8_t *dst_end = dst_ref + dst_capacity;

    yae_apply(atempo, &src_ref, src_end, &dst_ref, dst_end);

    *src_consumed = (size_t)(src_ref - (const uint8_t *)src);
    *dst_written = (size_t)(dst_ref - (uint8_t *)dst);
    return 0;
}

int sp_atempo_flush(struct sp_atempo *atempo,
                    void *dst,
                    size_t dst_capacity,
                    size_t *dst_written)
{
    if (!atempo || !dst_written) return -1;

    uint8_t *dst_ref = (uint8_t *)dst;
    uint8_t *dst_end = dst_ref + dst_capacity;
    int rc = yae_flush(atempo, &dst_ref, dst_end);

    *dst_written = (size_t)(dst_ref - (uint8_t *)dst);
    return rc == 0 ? 0 : 0; /* EAGAIN 时调用方按 dst_written 继续拉取 */
}

int sp_atempo_window(const struct sp_atempo *atempo)
{
    return atempo ? atempo->window : 0;
}

/* 供单测读取的内部状态，避免把字段暴露到公开头文件。 */
void sp_atempo_debug_state(const struct sp_atempo *atempo,
                           int *window,
                           int64_t *in_position,
                           int64_t *out_position)
{
    if (!atempo) return;
    if (window) *window = atempo->window;
    if (in_position) *in_position = atempo->position[0];
    if (out_position) *out_position = atempo->position[1];
}
