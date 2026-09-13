#include "sp_crypto.h"
#include "mp4_cenc.h"
#include "sp_aes.h"

#include <limits.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SP_READ_BYTES (64u * 1024u)
#define SP_MAX_SCAN_BYTES (4u * 1024u * 1024u)
#define SP_MAX_TOP_BOXES 4096u

typedef struct {
    uint64_t start;
    uint64_t end;
} media_range;

struct sp_stream {
    sp_io io;
    uint64_t size;
    uint64_t position;
    atomic_int cancelled;
    uint8_t *moov;
    uint64_t moov_offset;
    size_t moov_length;
    uint64_t *pssh_types;
    size_t pssh_count;
    sp_mp4_index index;
    sp_aes aes;
};

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static uint64_t be64(const uint8_t *p) {
    return ((uint64_t)be32(p) << 32) | be32(p + 4);
}

static int is_cancelled(const sp_stream *stream) {
    return atomic_load_explicit(&stream->cancelled, memory_order_acquire) != 0;
}

static sp_status read_exact(sp_stream *stream, uint64_t position, uint8_t *buffer,
                            size_t length, sp_error *error) {
    if (position > stream->size || (uint64_t)length > stream->size - position) {
        return sp_error_set(error, SP_ERR_FORMAT, "MP4 metadata extends past the file");
    }
    while (length != 0) {
        size_t requested = length < SP_READ_BYTES ? length : SP_READ_BYTES;
        if (is_cancelled(stream)) {
            return sp_error_set(error, SP_ERR_CANCELLED, "Stream cancelled");
        }
        ptrdiff_t count = stream->io.read_at(stream->io.user, position, buffer, requested);
        if (is_cancelled(stream)) {
            return sp_error_set(error, SP_ERR_CANCELLED, "Stream cancelled");
        }
        if (count <= 0 || (size_t)count > requested) {
            return sp_error_set(error, SP_ERR_IO, "Cannot read complete MP4 metadata");
        }
        position += (uint64_t)count;
        buffer += (size_t)count;
        length -= (size_t)count;
    }
    return SP_OK;
}

static void destroy_stream(sp_stream *stream, int owns_io) {
    if (stream == NULL) return;
    if (owns_io && stream->io.close != NULL) stream->io.close(stream->io.user);
    sp_mp4_index_dispose(&stream->index);
    free(stream->moov);
    free(stream->pssh_types);
    sp_aes_clear(&stream->aes);
    free(stream);
}

sp_stream *sp_stream_open(const sp_io *io, const uint8_t key[16], sp_error *error) {
    sp_error_set(error, SP_OK, NULL);
    if (io == NULL || io->size == NULL || io->read_at == NULL || key == NULL) {
        sp_error_set(error, SP_ERR_ARGUMENT, "Missing stream I/O or key");
        return NULL;
    }
    int64_t file_size = io->size(io->user);
    if (file_size < 8) {
        sp_error_set(error, file_size < 0 ? SP_ERR_IO : SP_ERR_FORMAT,
                     "Cannot determine a valid MP4 file length");
        return NULL;
    }
    sp_stream *stream = calloc(1, sizeof(*stream));
    if (stream == NULL) {
        sp_error_set(error, SP_ERR_MEMORY, "Cannot allocate crypto stream");
        return NULL;
    }
    stream->io = *io;
    stream->size = (uint64_t)file_size;
    atomic_init(&stream->cancelled, 0);
    sp_aes_init(&stream->aes, key);
    /* A top-level box needs only its header. In particular, scanning a tail
     * moov jumps over mdat without reading or buffering the movie payload. */
    media_range *media = calloc(SP_MAX_TOP_BOXES, sizeof(*media));
    if (media == NULL) {
        sp_error_set(error, SP_ERR_MEMORY, "Cannot allocate MP4 box index");
        destroy_stream(stream, 0);
        return NULL;
    }
    size_t media_count = 0;
    unsigned box_count = 0;
    uint64_t position = 0;
    uint64_t scanned_bytes = 0;
    uint8_t *scan = malloc(SP_READ_BYTES);
    if (scan == NULL) {
        sp_error_set(error, SP_ERR_MEMORY, "Cannot allocate MP4 header window");
        goto fail;
    }
    while (position < stream->size) {
        uint8_t header[16];
        size_t header_length = 8;
        int payload_read = 0;
        if (++box_count > SP_MAX_TOP_BOXES) {
            sp_error_set(error, SP_ERR_UNSUPPORTED, "Too many MP4 top-level boxes");
            goto fail;
        }
        if (read_exact(stream, position, header, 8, error) != SP_OK) goto fail;
        uint64_t box_length = be32(header);
        if (box_length == 1) {
            if (read_exact(stream, position + 8, header + 8, 8, error) != SP_OK) goto fail;
            box_length = be64(header + 8);
            header_length = 16;
        } else if (box_length == 0) {
            box_length = stream->size - position;
        }
        if (box_length < header_length || box_length > stream->size - position) {
            sp_error_set(error, SP_ERR_FORMAT, "Invalid MP4 top-level box length");
            goto fail;
        }
        if (memcmp(header + 4, "moof", 4) == 0) {
            sp_error_set(error, SP_ERR_UNSUPPORTED, "Fragmented MP4 is not supported");
            goto fail;
        }
        if (memcmp(header + 4, "moov", 4) == 0) {
            if (stream->moov != NULL) {
                sp_error_set(error, SP_ERR_FORMAT, "Multiple MP4 moov boxes");
                goto fail;
            }
            if (box_length > SP_MAX_MOOV_BYTES) {
                sp_error_set(error, SP_ERR_UNSUPPORTED, "MP4 metadata exceeds the memory limit");
                goto fail;
            }
            stream->moov_offset = position;
            stream->moov_length = (size_t)box_length;
            stream->moov = malloc(stream->moov_length);
            if (stream->moov == NULL) {
                sp_error_set(error, SP_ERR_MEMORY, "Cannot allocate MP4 metadata");
                goto fail;
            }
            memcpy(stream->moov, header, header_length);
            if (read_exact(stream, position + header_length, stream->moov + header_length,
                           stream->moov_length - header_length, error) != SP_OK) goto fail;
            payload_read = 1;
        } else if (memcmp(header + 4, "mdat", 4) == 0) {
            media[media_count].start = position + header_length;
            media[media_count].end = position + box_length;
            ++media_count;
        } else if (memcmp(header + 4, "pssh", 4) == 0) {
            if (stream->pssh_types == NULL) {
                stream->pssh_types = calloc(SP_MAX_TOP_BOXES, sizeof(*stream->pssh_types));
                if (stream->pssh_types == NULL) {
                    sp_error_set(error, SP_ERR_MEMORY, "Cannot allocate MP4 header patches");
                    goto fail;
                }
            }
            stream->pssh_types[stream->pssh_count++] = position + 4;
        }
        /* Consume short payloads of boxes we do not otherwise read, keeping
         * the byte stream contiguous for the next header. A file full of
         * short boxes must not issue one HTTP range request per box. mdat
         * payloads are still skipped so open never downloads movie data. */
        if (!payload_read && memcmp(header + 4, "mdat", 4) != 0 &&
            box_length - header_length <= SP_READ_BYTES &&
            scanned_bytes + (box_length - header_length) <= SP_MAX_SCAN_BYTES) {
            if (read_exact(stream, position + header_length, scan,
                           (size_t)(box_length - header_length), error) != SP_OK) goto fail;
            scanned_bytes += box_length - header_length;
        }
        position += box_length;
    }
    if (stream->moov == NULL || media_count == 0) {
        sp_error_set(error, SP_ERR_FORMAT, "MP4 needs moov and mdat boxes");
        goto fail;
    }
    if (sp_mp4_parse(stream->moov, stream->moov_length, stream->moov_offset,
                      stream->size, &stream->index, error) != SP_OK) goto fail;
    size_t media_index = 0;
    for (size_t i = 0; i < stream->index.sample_count; ++i) {
        const sp_sample *sample = &stream->index.samples[i];
        while (media_index < media_count && sample->offset >= media[media_index].end) {
            ++media_index;
        }
        if (media_index == media_count || sample->offset < media[media_index].start ||
            (uint64_t)sample->size > media[media_index].end - sample->offset) {
            sp_error_set(error, SP_ERR_FORMAT, "Encrypted sample is outside MP4 media data");
            goto fail;
        }
    }
    free(media);
    free(scan);
    return stream;

fail:
    free(media);
    free(scan);
    destroy_stream(stream, 0);
    return NULL;
}

static void decrypt_range(const sp_stream *stream, const sp_sample *sample,
                           uint64_t encrypted_start, uint32_t encrypted_length,
                           uint64_t encrypted_offset, uint64_t read_start,
                           size_t read_length, uint8_t *buffer) {
    uint64_t read_end = read_start + read_length;
    uint64_t encrypted_end = encrypted_start + encrypted_length;
    uint64_t start = read_start > encrypted_start ? read_start : encrypted_start;
    uint64_t end = read_end < encrypted_end ? read_end : encrypted_end;
    if (start < end) {
        sp_aes_ctr_xor(&stream->aes, sample->iv, sample->iv_size,
                       encrypted_offset + start - encrypted_start,
                       buffer + (size_t)(start - read_start), (size_t)(end - start));
    }
}

static void decrypt_buffer(const sp_stream *stream, uint64_t start, uint8_t *buffer,
                            size_t length) {
    const sp_mp4_index *index = &stream->index;
    size_t low = 0;
    size_t high = index->sample_count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        const sp_sample *sample = &index->samples[middle];
        if (sample->offset + sample->size <= start) low = middle + 1;
        else high = middle;
    }
    uint64_t end = start + length;
    for (size_t i = low; i < index->sample_count; ++i) {
        const sp_sample *sample = &index->samples[i];
        if (sample->offset >= end) break;
        if (sample->subsample_count == 0) {
            decrypt_range(stream, sample, sample->offset, sample->size, 0, start, length, buffer);
            continue;
        }
        uint64_t position = sample->offset;
        uint64_t encrypted_offset = 0;
        for (uint32_t j = 0; j < sample->subsample_count; ++j) {
            const sp_subsample *subsample = &index->subsamples[sample->subsample_start + j];
            position += subsample->clear_bytes;
            if (position >= end) break;
            decrypt_range(stream, sample, position, subsample->encrypted_bytes,
                           encrypted_offset, start, length, buffer);
            position += subsample->encrypted_bytes;
            encrypted_offset += subsample->encrypted_bytes;
        }
    }
}

static void patch_top_headers(const sp_stream *stream, uint64_t start, uint8_t *buffer,
                               size_t length) {
    static const uint8_t free_type[4] = {'f', 'r', 'e', 'e'};
    uint64_t end = start + length;
    for (size_t i = 0; i < stream->pssh_count; ++i) {
        uint64_t offset = stream->pssh_types[i];
        if (offset >= end) break;
        if (offset + 4 <= start) continue;
        uint64_t first = offset > start ? offset : start;
        uint64_t last = offset + 4 < end ? offset + 4 : end;
        memcpy(buffer + (size_t)(first - start), free_type + (size_t)(first - offset),
               (size_t)(last - first));
    }
}

ptrdiff_t sp_stream_read(sp_stream *stream, uint8_t *buffer, size_t length, sp_error *error) {
    sp_error_set(error, SP_OK, NULL);
    if (stream == NULL || (buffer == NULL && length != 0)) {
        return sp_error_set(error, SP_ERR_ARGUMENT, "Invalid stream read");
    }
    if (is_cancelled(stream)) return sp_error_set(error, SP_ERR_CANCELLED, "Stream cancelled");
    if (length == 0 || stream->position == stream->size) return 0;
    if (length > SP_READ_BYTES) length = SP_READ_BYTES;
    if ((uint64_t)length > stream->size - stream->position) {
        length = (size_t)(stream->size - stream->position);
    }
    if (stream->position >= stream->moov_offset &&
        stream->position < stream->moov_offset + stream->moov_length) {
        size_t offset = (size_t)(stream->position - stream->moov_offset);
        if (length > stream->moov_length - offset) length = stream->moov_length - offset;
        memcpy(buffer, stream->moov + offset, length);
        stream->position += length;
        return (ptrdiff_t)length;
    }
    if (stream->position < stream->moov_offset &&
        (uint64_t)length > stream->moov_offset - stream->position) {
        length = (size_t)(stream->moov_offset - stream->position);
    }
    ptrdiff_t count = stream->io.read_at(stream->io.user, stream->position, buffer, length);
    if (is_cancelled(stream)) return sp_error_set(error, SP_ERR_CANCELLED, "Stream cancelled");
    if (count <= 0 || (size_t)count > length) {
        return sp_error_set(error, SP_ERR_IO, "MP4 payload read failed or was truncated");
    }
    decrypt_buffer(stream, stream->position, buffer, (size_t)count);
    patch_top_headers(stream, stream->position, buffer, (size_t)count);
    stream->position += (uint64_t)count;
    return count;
}

int64_t sp_stream_seek(sp_stream *stream, int64_t position, sp_error *error) {
    sp_error_set(error, SP_OK, NULL);
    if (stream == NULL) return sp_error_set(error, SP_ERR_ARGUMENT, "Invalid stream seek");
    if (is_cancelled(stream)) return sp_error_set(error, SP_ERR_CANCELLED, "Stream cancelled");
    if (position < 0 || (uint64_t)position > stream->size) {
        return sp_error_set(error, SP_ERR_RANGE, "Seek position is outside the MP4 file");
    }
    if (stream->position != (uint64_t)position) {
        if (stream->io.cancel != NULL) stream->io.cancel(stream->io.user);
        stream->position = (uint64_t)position;
    }
    return position;
}

int64_t sp_stream_size(const sp_stream *stream) {
    return stream == NULL ? -1 : (int64_t)stream->size;
}

void sp_stream_cancel(sp_stream *stream) {
    if (stream == NULL) return;
    atomic_store_explicit(&stream->cancelled, 1, memory_order_release);
    if (stream->io.cancel != NULL) stream->io.cancel(stream->io.user);
}

void sp_stream_close(sp_stream *stream) {
    if (stream == NULL) return;
    sp_stream_cancel(stream);
    destroy_stream(stream, 1);
}
