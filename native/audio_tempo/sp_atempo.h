/*
 * WSOLA 时伸缩接口。算法来自 FFmpeg libavfilter/af_atempo.c 的移植
 * （LGPL-2.1-or-later），详见 sp_atempo.c 文件头。
 *
 * 用法：
 *   h = sp_atempo_create(48000, 2, 2.0);
 *   while (有输入) {
 *       sp_atempo_process(h, in, in_bytes, out, out_cap, &used, &written);
 *       消费 in[0..used) 与 out[0..written)；
 *       used == 0 && written == 0 表示还需要更多输入。
 *   }
 *   while (sp_atempo_flush(h, out, out_cap, &written) == 0 && written)
 *       消费 out[0..written)；
 *   sp_atempo_destroy(h);
 *
 * 输入输出都是 interleaved int16（ExoPlayer AudioProcessor 的唯一格式）。
 */
#ifndef SP_ATEMPO_H
#define SP_ATEMPO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct sp_atempo;

/* tempo 必须在 [0.5, 100.0]，与上游 YAE_ATEMPO_MIN/MAX 一致。 */
struct sp_atempo *sp_atempo_create(int sample_rate, int channels, double tempo);
void sp_atempo_destroy(struct sp_atempo *atempo);

/* 切换倍速。生效点与上游一致：下一次 process 时记入 origin 快照。 */
int sp_atempo_set_tempo(struct sp_atempo *atempo, double tempo);
double sp_atempo_get_tempo(const struct sp_atempo *atempo);

/*
 * 喂入 src_bytes、最多写出 dst_capacity。
 * 返回 0 表示正常；*src_consumed / *dst_written 说明这一轮的推进量。
 */
int sp_atempo_process(struct sp_atempo *atempo,
                      const void *src,
                      size_t src_bytes,
                      void *dst,
                      size_t dst_capacity,
                      size_t *src_consumed,
                      size_t *dst_written);

/* 冲掉内部残留（尾部的重叠区与余量）。 */
int sp_atempo_flush(struct sp_atempo *atempo,
                    void *dst,
                    size_t dst_capacity,
                    size_t *dst_written);

/* 当前分帧窗口长度（样本数），便于宿主决定缓冲大小。 */
int sp_atempo_window(const struct sp_atempo *atempo);

/* 单测用：读内部位置状态。 */
void sp_atempo_debug_state(const struct sp_atempo *atempo,
                           int *window,
                           int64_t *in_position,
                           int64_t *out_position);

#ifdef __cplusplus
}
#endif

#endif /* SP_ATEMPO_H */
