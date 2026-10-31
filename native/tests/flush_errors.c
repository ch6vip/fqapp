/*
 * 回归：sp_atempo_flush 的返回值契约。
 *
 * 1) yae_flush 的 -3 是「目标缓冲写满 / 还有残留」（等价上游的
 *    AVERROR(EAGAIN)），不是错误：sp_atempo_flush 必须返回 0，调用方按
 *    *dst_written 取走已写样本后继续调用。
 * 2) 其它负值必须原样传出。旧实现 `rc == 0 ? 0 : 0` 把内部错误也折成
 *    0，调用方会误以为已经排空，静默丢掉尾部音频。
 *
 * 第 2 条走不了公开 API（正常调用不会破坏位置不变量），所以白盒包含
 * 实现文件，构造一次 -6 分支。
 *
 * 逐行输出 key=value，供 test/native_atempo_test.cjs 断言。
 */
#include "../audio_tempo/sp_atempo.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

/* 白盒：为了拿到 struct sp_atempo 的内部状态，构造 yae_flush 的错误分支。 */
#include "../audio_tempo/sp_atempo.c"

#define RATE 48000
#define CH 1
#define BLOCK 4096
#define FEED_BLOCKS 8
#define OUT_CAP_SAMPLES (64u * 1024u)

static void fill_tone(int16_t *buf, size_t frames)
{
    for (size_t f = 0; f < frames; f++) {
        const double ph = 2.0 * M_PI * 440.0 * (double)f / (double)RATE;
        buf[f] = (int16_t)(sin(ph) * 8000.0);
    }
}

static int feed_all(struct sp_atempo *h, const int16_t *in, int16_t *out)
{
    for (int i = 0; i < FEED_BLOCKS; i++) {
        size_t used = 0;
        size_t written = 0;
        const int rc = sp_atempo_process(h, in, BLOCK * sizeof(int16_t), out,
                                         OUT_CAP_SAMPLES * sizeof(int16_t),
                                         &used, &written);
        if (rc != 0) return rc;
    }
    return 0;
}

int main(void)
{
    int16_t *in = (int16_t *)calloc(BLOCK, sizeof(int16_t));
    int16_t *out = (int16_t *)calloc(OUT_CAP_SAMPLES, sizeof(int16_t));
    if (!in || !out) return 3;
    fill_tone(in, BLOCK);

    /* 1) 小目标缓冲：一次只写得下一小段，每次调用都必须返回 0。 */
    struct sp_atempo *h = sp_atempo_create(RATE, CH, 2.0);
    if (!h) return 3;
    if (feed_all(h, in, out) != 0) return 4;

    size_t drained = 0;
    int eagain_rc = 0;
    for (int guard = 0; guard < 100000; guard++) {
        size_t written = 0;
        const int rc = sp_atempo_flush(h, out, 64, &written);
        if (rc != 0) {
            eagain_rc = rc;
            break;
        }
        drained += written;
        if (written == 0) break;
    }
    sp_atempo_destroy(h);

    /* 2) 破坏位置不变量，强制 yae_flush 走到 -6 分支：错误码必须传出。 */
    struct sp_atempo *bad = sp_atempo_create(RATE, CH, 2.0);
    if (!bad) return 3;
    if (feed_all(bad, in, out) != 0) return 4;
    const AudioFragment *frag = &bad->frag[bad->nfrag % 2];
    bad->position[0] = frag->position[0];
    bad->position[1] = frag->position[1] + frag->nsamples + 1;
    size_t written = 0;
    const int error_rc =
        sp_atempo_flush(bad, out, OUT_CAP_SAMPLES * sizeof(int16_t), &written);
    sp_atempo_destroy(bad);

    printf("eagain_rc=%d\n", eagain_rc);
    printf("drained_bytes=%zu\n", drained);
    printf("error_rc=%d\n", error_rc);

    free(out);
    free(in);
    return 0;
}
