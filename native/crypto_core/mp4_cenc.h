#ifndef SP_MP4_CENC_H
#define SP_MP4_CENC_H

#include "sp_crypto.h"

#define SP_MAX_MOOV_BYTES (16u * 1024u * 1024u)
#define SP_MAX_SAMPLES 1000000u
#define SP_MAX_SUBSAMPLES 2000000u

typedef struct {
    uint32_t clear_bytes;
    uint32_t encrypted_bytes;
} sp_subsample;

typedef struct {
    uint64_t offset;
    uint32_t size;
    uint8_t iv[16];
    uint8_t iv_size;
    uint32_t subsample_start;
    uint32_t subsample_count;
} sp_sample;

typedef struct {
    sp_sample *samples;
    size_t sample_count;
    sp_subsample *subsamples;
    size_t subsample_count;
} sp_mp4_index;

/* Parse one complete moov box, validate tables, and apply length-preserving
 * clear-track header patches in place. Only encrypted, nonempty samples enter
 * the index. Samples are sorted by absolute offset and must not overlap.
 * Caller zero-initializes index; on failure it remains safe to dispose. */
sp_status sp_mp4_parse(uint8_t *moov, size_t length, uint64_t moov_offset,
                       uint64_t file_size, sp_mp4_index *index, sp_error *error);
void sp_mp4_index_dispose(sp_mp4_index *index);

#endif
