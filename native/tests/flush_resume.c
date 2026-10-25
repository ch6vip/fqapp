/*
 * 回归：flush 之后继续喂输入必须能正常产帧（issue #129）。
 *
 * 曾经的 bug：yae_flush() 把状态置为 YAE_FLUSH_OUTPUT，而 yae_apply() 的
 * 状态机只匹配 YAE_LOAD_FRAGMENT 等四种，于是 seek / 循环播放之后再喂数据
 * 永远不产帧——用户侧表现为「拖动进度条之后没有声音」。
 */
#include "../audio_tempo/sp_atempo.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define RATE 48000
#define CH 1
#define BLOCK 4096

static size_t feed(struct sp_atempo *h, const int16_t *in, size_t frames,
                   int16_t *out, size_t out_cap)
{
    size_t used = 0, written = 0;
    sp_atempo_process(h, in, frames * sizeof(int16_t), out,
                      out_cap * sizeof(int16_t), &used, &written);
    return written / sizeof(int16_t);
}

int main(void) {
    const size_t out_cap = 1 << 16;
    int16_t *in = (int16_t *)calloc(BLOCK, sizeof(int16_t));
    int16_t *out = (int16_t *)calloc(out_cap, sizeof(int16_t));
    if (!in || !out) return 3;

    for (size_t f = 0; f < BLOCK; f++) {
        const double ph = 2.0 * M_PI * 440.0 * (double)f / (double)RATE;
        in[f] = (int16_t)(sin(ph) * 8000.0);
    }

    struct sp_atempo *h = sp_atempo_create(RATE, CH, 2.0);
    if (!h) return 3;

    /* 第一段：正常播放 */
    size_t total_first = 0;
    for (int i = 0; i < 8; i++) total_first += feed(h, in, BLOCK, out, out_cap);

    /* flush（等价于 seek / 播到结尾） */
    size_t flushed = 0;
    sp_atempo_flush(h, out, out_cap * sizeof(int16_t), &flushed);

    /* 第二段：flush 之后继续喂同样的数据，必须还能产帧 */
    size_t total_second = 0;
    for (int i = 0; i < 8; i++) total_second += feed(h, in, BLOCK, out, out_cap);

    printf("first_segment_frames=%zu\n", total_first);
    printf("flushed_frames=%zu\n", flushed / sizeof(int16_t));
    printf("second_segment_frames=%zu\n", total_second);

    sp_atempo_destroy(h);
    free(out);
    free(in);
    return 0;
}
