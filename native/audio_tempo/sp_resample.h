/*
 * 变速前置重采样（issue #129，对齐番茄官方 atempo 之前的 samplefilter）。
 *
 * 见 sp_resample.c 的实现说明。
 */
#ifndef SP_RESAMPLE_H
#define SP_RESAMPLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct sp_resampler;

struct sp_resampler *sp_resampler_create(int in_rate, int out_rate, int channels);
void sp_resampler_destroy(struct sp_resampler *r);

/* 清空跨块状态（seek / 换曲时调用）。 */
void sp_resampler_reset(struct sp_resampler *r);

/*
 * 处理一段交错 int16，返回写入 out 的帧数。
 * 输出容量用 sp_resampler_output_bound 估算。
 */
size_t sp_resampler_process(struct sp_resampler *r,
                            const int16_t *in,
                            size_t in_frames,
                            int16_t *out,
                            size_t out_capacity_frames);

size_t sp_resampler_output_bound(const struct sp_resampler *r, size_t in_frames);

#ifdef __cplusplus
}
#endif

#endif /* SP_RESAMPLE_H */
