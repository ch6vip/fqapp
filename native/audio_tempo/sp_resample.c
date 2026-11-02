/*
 * 变速前置重采样，对齐番茄官方听书链路（issue #129）。
 *
 * 官方在 atempo 之前先把 PCM 统一到输出采样率——`libttmplayer.so` 的日志
 * 就是这一句：
 *
 *   build ppl: in-sampleRate: %d, out-sampleRate: %d, in-Format: %d,
 *              out-Format: %d, in-Channels: %d, out-Channels: %d, speed: %f
 *
 * 为什么必须做：WSOLA 的窗口是 `sample_rate / 24`（见 sp_atempo.c），24 kHz
 * 的 TTS 只有 1024 点窗口，48 kHz 有 2048 点。窗口越小，互相关的周期估计
 * 越粗，高倍速下越容易选错拼接点——这正是「电音」的来源之一。
 *
 * 算法：线性插值。官方那段是 swresample，听书语音带宽有限，24k→48k 的
 * 混叠落在 12 kHz 以上，智能朗读的语谱基本吃不到。将来接音乐内容时应换成
 * 带抗混叠 FIR 的实现。
 */
#include "sp_resample.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct sp_resampler {
    int in_rate;
    int out_rate;
    int channels;
    /*
     * 相位用 Q16 定点。必须是 64 位：step_q16 在 48k<=>48k 时是 65536，
     * 单块 10 万帧就会把 32 位累加器推到 2^32 以上而回绕，表现为多吐样本
     * 与爆音（真机上单次 queueInput 虽然只有几十 KB，但 flush 路径会累积）。
     */
    uint64_t step_q16;
    int64_t phase_q16;
    int has_previous;
    /* 上一块最后一个输入帧：跨块插值时作为「第 -1 帧」 */
    int16_t *prev_frame;
};

struct sp_resampler *sp_resampler_create(int in_rate, int out_rate, int channels)
{
    if (in_rate <= 0 || out_rate <= 0 || channels <= 0 ||
        (size_t)channels > SIZE_MAX / sizeof(int16_t)) return NULL;
    struct sp_resampler *r = (struct sp_resampler *)calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->in_rate = in_rate;
    r->out_rate = out_rate;
    r->channels = channels;
    r->step_q16 = ((uint64_t)(unsigned)in_rate << 16) /
                  (uint64_t)(unsigned)out_rate;
    r->phase_q16 = 0;
    if (r->step_q16 == 0 || r->step_q16 > INT64_MAX) {
        free(r);
        return NULL;
    }
    r->prev_frame = (int16_t *)calloc((size_t)channels, sizeof(int16_t));
    if (!r->prev_frame) {
        free(r);
        return NULL;
    }
    return r;
}

void sp_resampler_destroy(struct sp_resampler *r)
{
    if (!r) return;
    free(r->prev_frame);
    free(r);
}

void sp_resampler_reset(struct sp_resampler *r)
{
    if (!r) return;
    r->phase_q16 = 0;
    r->has_previous = 0;
    if (r->prev_frame) {
        memset(r->prev_frame, 0, sizeof(int16_t) * (size_t)r->channels);
    }
}

/*
 * 处理一段交错 int16。返回写入输出的帧数。
 *
 * 相位语义：`phase_q16 >> 16` 是相对**当前输入起始帧**的整数偏移，
 * `phase & 0xFFFF` 是小数部分。跨块时用 [prev_frame, in[0]] 插值。
 *
 * Capacity must cover the checked bound; a rejected call does not accept input.
 */
size_t sp_resampler_process(struct sp_resampler *r,
                            const int16_t *in,
                            size_t in_frames,
                            int16_t *out,
                            size_t out_capacity_frames)
{
    if (!r || !in || !out) return SIZE_MAX;
    if (in_frames == 0) return 0;
    const size_t bound = sp_resampler_output_bound(r, in_frames);
    if (bound == SIZE_MAX || out_capacity_frames < bound ||
        in_frames > SIZE_MAX / (size_t)r->channels / sizeof(int16_t) ||
        bound > SIZE_MAX / (size_t)r->channels / sizeof(int16_t) ||
        (r->phase_q16 < 0 && !r->has_previous)) return SIZE_MAX;

    const int ch = r->channels;
    const int64_t step = (int64_t)r->step_q16;
    int64_t phase = r->phase_q16;
    size_t out_frames = 0;

    /* 输入帧号用 int64 表达，避免大缓冲溢出；-1 表示 prev_frame。 */
    for (;;) {
        int64_t base = phase / 65536;
        int64_t remainder = phase % 65536;
        if (remainder < 0) {
            --base;
            remainder += 65536;
        }
        if (base >= (int64_t)in_frames) break;
        if (out_frames >= out_capacity_frames) break;

        const uint32_t frac = (uint32_t)remainder;
        // The fractional last sample needs the next block's first neighbor.
        if (base == (int64_t)in_frames - 1 && frac != 0) break;

        const int16_t *f0;
        const int16_t *f1;
        if (base < 0) {
            f0 = r->prev_frame;
            f1 = in;
        } else if (base + 1 < (int64_t)in_frames) {
            f0 = in + (size_t)base * (size_t)ch;
            f1 = f0 + ch;
        } else {
            /* An exact integer last frame needs no next neighbor. */
            f0 = in + (size_t)base * (size_t)ch;
            f1 = f0;
        }

        int16_t *dst = out + out_frames * (size_t)ch;
        for (int c = 0; c < ch; c++) {
            const int32_t a = f0[c];
            const int32_t b = f1[c];
            dst[c] = (int16_t)(a + (((int64_t)(b - a) * (int64_t)frac) >> 16));
        }
        out_frames++;

        /* 前进一个输出帧对应的输入量，整数部分进位到下一轮 */
        phase += step;
    }

    r->phase_q16 = phase - (int64_t)(in_frames * 65536);

    /* 记录本块最后一帧，供下一块在 base<0 时插值 */
    if (in_frames > 0) {
        memcpy(r->prev_frame, in + (in_frames - 1) * (size_t)ch,
               sizeof(int16_t) * (size_t)ch);
    }
    r->has_previous = 1;
    return out_frames;
}

/* 一次处理所需的输出容量（帧数），调用方按它分配。 */
size_t sp_resampler_output_bound(const struct sp_resampler *r, size_t in_frames)
{
    if (!r || r->step_q16 == 0 || r->phase_q16 < -65535 ||
        in_frames > (uint64_t)(INT64_MAX - 65536) / 65536) return SIZE_MAX;
    if (in_frames == 0) return 0;
    const uint64_t span = (uint64_t)in_frames * 65536;
    const int64_t phase = r->phase_q16;
    if (phase >= 0 && (uint64_t)phase >= span) return 0;
    const uint64_t distance = phase < 0 ? span + (uint64_t)(-phase)
                                       : span - (uint64_t)phase;
    const uint64_t count = distance / r->step_q16 + (distance % r->step_q16 != 0);
    const uint64_t positive_phase = phase > 0 ? (uint64_t)phase : 0;
    if (count > SIZE_MAX || count > (INT64_MAX - positive_phase) / r->step_q16) {
        return SIZE_MAX;
    }
    return (size_t)count;
}

size_t sp_resampler_flush_bound(const struct sp_resampler *r)
{
    if (!r || r->step_q16 == 0 || r->phase_q16 < -65535) return SIZE_MAX;
    if (!r->has_previous || r->phase_q16 >= 0) return 0;
    const uint64_t distance = (uint64_t)(-r->phase_q16);
    return (size_t)(distance / r->step_q16 + (distance % r->step_q16 != 0));
}

size_t sp_resampler_flush(struct sp_resampler *r, int16_t *out, size_t capacity)
{
    const size_t bound = sp_resampler_flush_bound(r);
    if (bound == SIZE_MAX || !out ||
        capacity > SIZE_MAX / (size_t)r->channels / sizeof(int16_t)) return SIZE_MAX;
    const size_t count = bound < capacity ? bound : capacity;
    for (size_t i = 0; i < count; ++i) {
        memcpy(out + i * (size_t)r->channels, r->prev_frame,
               (size_t)r->channels * sizeof(int16_t));
        r->phase_q16 += (int64_t)r->step_q16;
    }
    return count;
}
