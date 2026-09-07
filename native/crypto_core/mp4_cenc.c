/* Non-fragmented ISO BMFF / Common Encryption indexer.
 *
 * This parser deliberately accepts a small, explicit CENC profile. In
 * particular, it never removes protection metadata before every encrypted
 * track and all of its sample ranges have been validated. Unknown encryption
 * modes must fail here, rather than returning an apparently clear MP4.
 */
#include "mp4_cenc.h"

#include <stdlib.h>
#include <string.h>

#define FOURCC(a, b, c, d) \
    (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
     ((uint32_t)(c) << 8) | (uint32_t)(d))
#define TRY(expression) do { \
    sp_status try_status = (expression); \
    if (try_status != SP_OK) return try_status; \
} while (0)

typedef struct {
    size_t start;
    size_t payload;
    size_t end;
    uint32_t type;
    int present;
} mp4_box;

typedef struct {
    size_t offset;
    uint32_t type;
} type_patch;

typedef struct {
    uint8_t *data;
    size_t length;
    uint64_t moov_offset;
    uint64_t file_size;
    sp_mp4_index *index;
    sp_error *error;
    size_t sample_capacity;
    size_t subsample_capacity;
    size_t samples_seen;
    size_t subsamples_seen;
    type_patch *patches;
    size_t patch_count;
    size_t patch_capacity;
    uint8_t kid[16];
    int has_kid;
} parse_context;

typedef struct {
    int encrypted;
    uint8_t iv_size;
    mp4_box description;
    mp4_box protection;
    uint32_t original_format;
} protection_info;

typedef struct {
    mp4_box stsd;
    mp4_box stsz;
    mp4_box stz2;
    mp4_box stsc;
    mp4_box chunks;
    mp4_box senc;
    mp4_box saiz;
    mp4_box saio;
} sample_tables;

typedef struct {
    size_t sizes;
    size_t chunks;
    size_t stsc;
    uint32_t fixed_size;
    uint32_t sample_count;
    uint32_t chunk_count;
    uint32_t stsc_count;
    size_t chunk_width;
} table_view;

typedef struct {
    int present;
    uint8_t fixed_size;
    size_t sizes;
} auxiliary_sizes;

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t read_u32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t read_u64(const uint8_t *p) {
    return ((uint64_t)read_u32(p) << 32) | read_u32(p + 4);
}

static void write_u32(uint8_t *p, uint32_t value) {
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

static sp_status box_error(parse_context *context, const mp4_box *box,
                           sp_status code, const char *message) {
    uint32_t type = box->type;
    return sp_error_set(context->error, code, "MP4 %c%c%c%c: %s",
                        (int)(type >> 24), (int)((type >> 16) & 255),
                        (int)((type >> 8) & 255), (int)(type & 255), message);
}

/* All size arithmetic below is relative to the current box, not to moov as
 * a whole. A damaged child cannot borrow bytes from its following sibling. */
static sp_status next_box(parse_context *context, size_t *cursor,
                          size_t parent_end, mp4_box *box) {
    size_t start = *cursor;
    size_t header = 8;
    uint64_t size;
    if (start > parent_end || parent_end > context->length ||
        parent_end - start < 8) {
        return sp_error_set(context->error, SP_ERR_FORMAT,
                            "MP4 truncated box header");
    }
    size = read_u32(context->data + start);
    box->type = read_u32(context->data + start + 4);
    if (size == 1) {
        if (parent_end - start < 16) {
            return box_error(context, box, SP_ERR_FORMAT,
                             "truncated extended size");
        }
        header = 16;
        size = read_u64(context->data + start + 8);
    } else if (size == 0) {
        size = parent_end - start;
    }
    if (size < header || size > parent_end - start) {
        return box_error(context, box, SP_ERR_FORMAT,
                         "size exceeds containing box");
    }
    box->start = start;
    box->payload = start + header;
    box->end = start + (size_t)size;
    box->present = 1;
    *cursor = box->end;
    return SP_OK;
}

static sp_status full_box(parse_context *context, const mp4_box *box,
                          uint8_t max_version, uint32_t allowed_flags,
                          uint8_t *version, uint32_t *flags) {
    uint32_t value;
    if (box->end - box->payload < 4) {
        return box_error(context, box, SP_ERR_FORMAT, "missing FullBox header");
    }
    value = read_u32(context->data + box->payload);
    *version = (uint8_t)(value >> 24);
    *flags = value & 0x00ffffffu;
    if (*version > max_version || (*flags & ~allowed_flags) != 0) {
        return box_error(context, box, SP_ERR_UNSUPPORTED,
                         "unsupported version or flags");
    }
    return SP_OK;
}

static sp_status unique_box(parse_context *context, mp4_box *destination,
                            const mp4_box *box) {
    if (destination->present) {
        return box_error(context, box, SP_ERR_FORMAT, "duplicate table or box");
    }
    *destination = *box;
    return SP_OK;
}

static sp_status grow_array(parse_context *context, void *buffer,
                            size_t *capacity, size_t count, size_t element_size,
                            size_t limit, void **replacement) {
    size_t new_capacity;
    void *resized;
    if (count > limit || count > SIZE_MAX / element_size) {
        return sp_error_set(context->error, SP_ERR_RANGE,
                            "MP4 index allocation limit exceeded");
    }
    if (count <= *capacity) {
        *replacement = buffer;
        return SP_OK;
    }
    new_capacity = *capacity ? *capacity : 16;
    if (new_capacity > limit) new_capacity = limit;
    while (new_capacity < count) {
        if (new_capacity > limit / 2) {
            new_capacity = limit;
            break;
        }
        new_capacity *= 2;
    }
    if (new_capacity > SIZE_MAX / element_size) new_capacity = count;
    resized = realloc(buffer, new_capacity * element_size);
    if (!resized) {
        return sp_error_set(context->error, SP_ERR_MEMORY,
                            "Cannot allocate MP4 sample index");
    }
    *capacity = new_capacity;
    *replacement = resized;
    return SP_OK;
}

static sp_status add_patch(parse_context *context, const mp4_box *box,
                           uint32_t type) {
    void *replacement;
    TRY(grow_array(context, context->patches, &context->patch_capacity,
                   context->patch_count + 1, sizeof(type_patch),
                   context->length / 8, &replacement));
    context->patches = (type_patch *)replacement;
    context->patches[context->patch_count].offset = box->start + 4;
    context->patches[context->patch_count].type = type;
    ++context->patch_count;
    return SP_OK;
}

static int encrypted_entry(uint32_t type) {
    return (type & 0xffffff00u) == FOURCC('e', 'n', 'c', 0) ||
           type == FOURCC('d', 'r', 'm', 'i') ||
           type == FOURCC('d', 'r', 'm', 's');
}

static sp_status parse_tenc(parse_context *context, const mp4_box *box,
                            protection_info *protection) {
    uint8_t version;
    uint32_t flags;
    const uint8_t *p = context->data + box->payload;
    TRY(full_box(context, box, 1, 0, &version, &flags));
    if (box->end - box->payload < 24) {
        return box_error(context, box, SP_ERR_FORMAT, "truncated track encryption");
    }
    if (p[4] != 0 || (version == 0 && p[5] != 0)) {
        return box_error(context, box, SP_ERR_FORMAT, "nonzero reserved field");
    }
    if (version == 1 && p[5] != 0) {
        return box_error(context, box, SP_ERR_UNSUPPORTED,
                         "pattern encryption is not supported");
    }
    if (p[6] != 1) {
        return box_error(context, box,
                         p[6] == 0 ? SP_ERR_UNSUPPORTED : SP_ERR_FORMAT,
                         "only default protected samples are supported");
    }
    if (p[7] != 8 && p[7] != 16) {
        return box_error(context, box, SP_ERR_UNSUPPORTED,
                         "only per-sample 8- or 16-byte IVs are supported");
    }
    if (box->end - box->payload != 24) {
        return box_error(context, box, SP_ERR_FORMAT,
                         "unexpected track encryption payload");
    }
    if (context->has_kid && memcmp(context->kid, p + 8, 16) != 0) {
        return box_error(context, box, SP_ERR_UNSUPPORTED,
                         "multiple content key IDs are not supported");
    }
    memcpy(context->kid, p + 8, 16);
    context->has_kid = 1;
    protection->iv_size = p[7];
    return SP_OK;
}

static sp_status parse_schi(parse_context *context, const mp4_box *box,
                            protection_info *protection) {
    mp4_box tenc = {0};
    size_t position = box->payload;
    while (position < box->end) {
        mp4_box child;
        TRY(next_box(context, &position, box->end, &child));
        if (child.type == FOURCC('t', 'e', 'n', 'c')) {
            TRY(unique_box(context, &tenc, &child));
        }
    }
    if (!tenc.present) {
        return box_error(context, box, SP_ERR_UNSUPPORTED,
                         "missing standard tenc encryption parameters");
    }
    return parse_tenc(context, &tenc, protection);
}

static sp_status parse_sinf(parse_context *context, const mp4_box *box,
                            protection_info *protection) {
    mp4_box frma = {0}, schm = {0}, schi = {0};
    uint8_t version;
    uint32_t flags;
    size_t position = box->payload;
    size_t remaining;
    const uint8_t *p;
    while (position < box->end) {
        mp4_box child;
        TRY(next_box(context, &position, box->end, &child));
        switch (child.type) {
            case FOURCC('f', 'r', 'm', 'a'):
                TRY(unique_box(context, &frma, &child));
                break;
            case FOURCC('s', 'c', 'h', 'm'):
                TRY(unique_box(context, &schm, &child));
                break;
            case FOURCC('s', 'c', 'h', 'i'):
                TRY(unique_box(context, &schi, &child));
                break;
            default:
                break;
        }
    }
    if (!frma.present || !schm.present || !schi.present) {
        return box_error(context, box, SP_ERR_FORMAT,
                         "incomplete protection scheme information");
    }
    if (frma.end - frma.payload != 4) {
        return box_error(context, &frma, SP_ERR_FORMAT, "invalid original format");
    }
    protection->original_format = read_u32(context->data + frma.payload);
    if (!protection->original_format || encrypted_entry(protection->original_format)) {
        return box_error(context, &frma, SP_ERR_UNSUPPORTED,
                         "original format is not a clear sample entry");
    }
    TRY(full_box(context, &schm, 0, 1, &version, &flags));
    remaining = schm.end - schm.payload;
    if (remaining < 12) {
        return box_error(context, &schm, SP_ERR_FORMAT, "truncated scheme type");
    }
    p = context->data + schm.payload;
    if (read_u32(p + 4) != FOURCC('c', 'e', 'n', 'c') ||
        read_u32(p + 8) != 0x00010000u) {
        return box_error(context, &schm, SP_ERR_UNSUPPORTED,
                         "only cenc AES-CTR scheme version 1 is supported");
    }
    if ((flags == 0 && remaining != 12) ||
        (flags != 0 && (remaining < 13 || p[remaining - 1] != 0))) {
        return box_error(context, &schm, SP_ERR_FORMAT, "invalid scheme URI payload");
    }
    TRY(parse_schi(context, &schi, protection));
    protection->protection = *box;
    return SP_OK;
}

static sp_status parse_encrypted_entry(parse_context *context, const mp4_box *entry,
                                       protection_info *protection) {
    size_t fields;
    size_t position;
    mp4_box sinf = {0};
    if (entry->type == FOURCC('e', 'n', 'c', 'v')) {
        fields = 78;
    } else if (entry->type == FOURCC('e', 'n', 'c', 'a')) {
        uint16_t version;
        if (entry->end - entry->payload < 28) {
            return box_error(context, entry, SP_ERR_FORMAT,
                             "truncated audio sample entry");
        }
        version = read_u16(context->data + entry->payload + 8);
        if (version > 1) {
            return box_error(context, entry, SP_ERR_UNSUPPORTED,
                             "unsupported audio sample entry version");
        }
        fields = version == 1 ? 44 : 28;
    } else {
        return box_error(context, entry, SP_ERR_UNSUPPORTED,
                         "only encrypted video and audio sample entries are supported");
    }
    if (entry->end - entry->payload < fields) {
        return box_error(context, entry, SP_ERR_FORMAT, "truncated sample entry");
    }
    if (read_u16(context->data + entry->payload + 6) != 1) {
        return box_error(context, entry, SP_ERR_UNSUPPORTED,
                         "only data reference index 1 is supported");
    }
    position = entry->payload + fields;
    while (position < entry->end) {
        mp4_box child;
        TRY(next_box(context, &position, entry->end, &child));
        if (child.type == FOURCC('s', 'i', 'n', 'f')) {
            TRY(unique_box(context, &sinf, &child));
        }
    }
    if (!sinf.present) {
        return box_error(context, entry, SP_ERR_FORMAT,
                         "encrypted sample entry has no sinf");
    }
    TRY(parse_sinf(context, &sinf, protection));
    protection->encrypted = 1;
    protection->description = *entry;
    return SP_OK;
}

static sp_status parse_stsd(parse_context *context, const mp4_box *box,
                            protection_info *protection) {
    uint8_t version;
    uint32_t flags, count, i;
    size_t position;
    TRY(full_box(context, box, 0, 0, &version, &flags));
    if (box->end - box->payload < 8) {
        return box_error(context, box, SP_ERR_FORMAT, "missing description count");
    }
    count = read_u32(context->data + box->payload + 4);
    position = box->payload + 8;
    if (count > (box->end - position) / 8) {
        return box_error(context, box, SP_ERR_FORMAT, "description count exceeds box");
    }
    for (i = 0; i < count; ++i) {
        mp4_box entry;
        TRY(next_box(context, &position, box->end, &entry));
        if (entry.end - entry.payload < 8) {
            return box_error(context, &entry, SP_ERR_FORMAT, "truncated sample entry");
        }
        if (encrypted_entry(entry.type)) {
            if (count != 1) {
                return box_error(context, box, SP_ERR_UNSUPPORTED,
                                 "multiple descriptions on an encrypted track");
            }
            TRY(parse_encrypted_entry(context, &entry, protection));
        }
    }
    if (position != box->end) {
        return box_error(context, box, SP_ERR_FORMAT, "trailing sample descriptions");
    }
    return SP_OK;
}

static sp_status check_sample_group(parse_context *context, const mp4_box *box) {
    uint8_t version;
    uint32_t flags;
    uint8_t max_version = box->type == FOURCC('s', 'g', 'p', 'd') ? 2 : 1;
    TRY(full_box(context, box, max_version, 0, &version, &flags));
    if (box->end - box->payload < 8) {
        return box_error(context, box, SP_ERR_FORMAT, "missing grouping type");
    }
    if (read_u32(context->data + box->payload + 4) == FOURCC('s', 'e', 'i', 'g')) {
        return box_error(context, box, SP_ERR_UNSUPPORTED,
                         "seig sample encryption overrides are not supported");
    }
    return SP_OK;
}

static sp_status collect_tables(parse_context *context, const mp4_box *stbl,
                                sample_tables *tables) {
    size_t position = stbl->payload;
    while (position < stbl->end) {
        mp4_box child;
        TRY(next_box(context, &position, stbl->end, &child));
        switch (child.type) {
            case FOURCC('s', 't', 's', 'd'):
                TRY(unique_box(context, &tables->stsd, &child)); break;
            case FOURCC('s', 't', 's', 'z'):
                TRY(unique_box(context, &tables->stsz, &child)); break;
            case FOURCC('s', 't', 'z', '2'):
                TRY(unique_box(context, &tables->stz2, &child)); break;
            case FOURCC('s', 't', 's', 'c'):
                TRY(unique_box(context, &tables->stsc, &child)); break;
            case FOURCC('s', 't', 'c', 'o'):
            case FOURCC('c', 'o', '6', '4'):
                TRY(unique_box(context, &tables->chunks, &child)); break;
            case FOURCC('s', 'e', 'n', 'c'):
                TRY(unique_box(context, &tables->senc, &child)); break;
            case FOURCC('s', 'a', 'i', 'z'):
                TRY(unique_box(context, &tables->saiz, &child)); break;
            case FOURCC('s', 'a', 'i', 'o'):
                TRY(unique_box(context, &tables->saio, &child)); break;
            case FOURCC('s', 'g', 'p', 'd'):
            case FOURCC('s', 'b', 'g', 'p'):
                TRY(check_sample_group(context, &child)); break;
            case FOURCC('u', 'u', 'i', 'd'): {
                /* PIFF SampleEncryptionBox is not the standard senc profile. */
                static const uint8_t piff_senc[16] = {
                    0xa2, 0x39, 0x4f, 0x52, 0x5a, 0x9b, 0x4f, 0x14,
                    0xa2, 0x44, 0x6c, 0x42, 0x7c, 0x64, 0x8d, 0xf4
                };
                if (child.end - child.payload < 16) {
                    return box_error(context, &child, SP_ERR_FORMAT,
                                     "truncated UUID user type");
                }
                if (memcmp(context->data + child.payload, piff_senc, 16) == 0) {
                    return box_error(context, &child, SP_ERR_UNSUPPORTED,
                                     "PIFF encryption is not supported");
                }
                break;
            }
            default:
                break;
        }
    }
    if (!tables->stsd.present) {
        return box_error(context, stbl, SP_ERR_FORMAT, "missing sample descriptions");
    }
    return SP_OK;
}

static sp_status parse_table_view(parse_context *context,
                                  const sample_tables *tables, table_view *view) {
    const mp4_box *stsz = &tables->stsz;
    const mp4_box *stsc = &tables->stsc;
    const mp4_box *chunks = &tables->chunks;
    uint8_t version;
    uint32_t flags, i, previous = 0;
    uint64_t mapped = 0;
    if (tables->stz2.present) {
        return box_error(context, &tables->stz2, SP_ERR_UNSUPPORTED,
                         "compact sample sizes are not supported");
    }
    if (!stsz->present || !stsc->present || !chunks->present) {
        return sp_error_set(context->error, SP_ERR_FORMAT,
                            "MP4 track is missing a required sample table");
    }
    TRY(full_box(context, stsz, 0, 0, &version, &flags));
    if (stsz->end - stsz->payload < 12) {
        return box_error(context, stsz, SP_ERR_FORMAT, "truncated sample size table");
    }
    view->fixed_size = read_u32(context->data + stsz->payload + 4);
    view->sample_count = read_u32(context->data + stsz->payload + 8);
    view->sizes = stsz->payload + 12;
    if (view->sample_count > SP_MAX_SAMPLES - context->samples_seen) {
        return box_error(context, stsz, SP_ERR_RANGE, "sample limit exceeded");
    }
    if (view->fixed_size != 0) {
        if (view->sizes != stsz->end) {
            return box_error(context, stsz, SP_ERR_FORMAT,
                             "fixed sample size table contains extra data");
        }
    } else if ((size_t)view->sample_count != (stsz->end - view->sizes) / 4 ||
               (stsz->end - view->sizes) % 4 != 0) {
        return box_error(context, stsz, SP_ERR_FORMAT, "sample size count mismatch");
    }
    TRY(full_box(context, chunks, 0, 0, &version, &flags));
    if (chunks->end - chunks->payload < 8) {
        return box_error(context, chunks, SP_ERR_FORMAT, "truncated chunk offsets");
    }
    view->chunk_count = read_u32(context->data + chunks->payload + 4);
    view->chunks = chunks->payload + 8;
    view->chunk_width = chunks->type == FOURCC('c', 'o', '6', '4') ? 8 : 4;
    if (view->chunk_count > SP_MAX_SAMPLES) {
        return box_error(context, chunks, SP_ERR_RANGE, "chunk limit exceeded");
    }
    if ((size_t)view->chunk_count != (chunks->end - view->chunks) / view->chunk_width ||
        (chunks->end - view->chunks) % view->chunk_width != 0) {
        return box_error(context, chunks, SP_ERR_FORMAT, "chunk offset count mismatch");
    }
    TRY(full_box(context, stsc, 0, 0, &version, &flags));
    if (stsc->end - stsc->payload < 8) {
        return box_error(context, stsc, SP_ERR_FORMAT, "truncated sample-to-chunk table");
    }
    view->stsc_count = read_u32(context->data + stsc->payload + 4);
    view->stsc = stsc->payload + 8;
    if ((size_t)view->stsc_count != (stsc->end - view->stsc) / 12 ||
        (stsc->end - view->stsc) % 12 != 0) {
        return box_error(context, stsc, SP_ERR_FORMAT, "sample-to-chunk count mismatch");
    }
    if (view->sample_count == 0) {
        if (view->chunk_count != 0 || view->stsc_count != 0) {
            return box_error(context, stsc, SP_ERR_FORMAT,
                             "empty track contains chunk mappings");
        }
        return SP_OK;
    }
    if (view->chunk_count == 0 || view->stsc_count == 0 ||
        view->stsc_count > view->chunk_count) {
        return box_error(context, stsc, SP_ERR_FORMAT, "invalid chunk mapping count");
    }
    for (i = 0; i < view->stsc_count; ++i) {
        const uint8_t *entry = context->data + view->stsc + (size_t)i * 12;
        uint32_t first = read_u32(entry);
        uint32_t per_chunk = read_u32(entry + 4);
        uint32_t next = i + 1 < view->stsc_count
                      ? read_u32(entry + 12) : view->chunk_count + 1;
        if ((i == 0 && first != 1) || first <= previous ||
            first > view->chunk_count || next <= first ||
            next > view->chunk_count + 1 || per_chunk == 0) {
            return box_error(context, stsc, SP_ERR_FORMAT, "invalid chunk mapping range");
        }
        if (read_u32(entry + 8) != 1) {
            return box_error(context, stsc, SP_ERR_UNSUPPORTED,
                             "sample description index is not 1");
        }
        mapped += (uint64_t)(next - first) * per_chunk;
        if (mapped > view->sample_count) {
            return box_error(context, stsc, SP_ERR_FORMAT,
                             "chunk mappings contain too many samples");
        }
        previous = first;
    }
    if (mapped != view->sample_count) {
        return box_error(context, stsc, SP_ERR_FORMAT,
                         "chunk mappings omit declared samples");
    }
    return SP_OK;
}

static sp_status map_samples(parse_context *context, const table_view *view,
                             sp_sample *samples) {
    uint32_t chunk, mapping = 0, sample_index = 0;
    for (chunk = 0; chunk < view->chunk_count; ++chunk) {
        const uint8_t *chunk_data = context->data + view->chunks +
                                    (size_t)chunk * view->chunk_width;
        uint64_t offset = view->chunk_width == 8
                        ? read_u64(chunk_data) : read_u32(chunk_data);
        uint32_t per_chunk, j;
        while (mapping + 1 < view->stsc_count &&
               read_u32(context->data + view->stsc + (size_t)(mapping + 1) * 12)
                   <= chunk + 1) {
            ++mapping;
        }
        per_chunk = read_u32(context->data + view->stsc + (size_t)mapping * 12 + 4);
        for (j = 0; j < per_chunk; ++j) {
            uint32_t size = view->fixed_size ? view->fixed_size
                : read_u32(context->data + view->sizes + (size_t)sample_index * 4);
            sp_sample *sample = samples + sample_index;
            if (offset > context->file_size || size > context->file_size - offset) {
                return sp_error_set(context->error, SP_ERR_FORMAT,
                                    "MP4 sample extends beyond the file");
            }
            if (size != 0 && offset < context->moov_offset + context->length &&
                offset + size > context->moov_offset) {
                return sp_error_set(context->error, SP_ERR_FORMAT,
                                    "MP4 sample overlaps moov metadata");
            }
            memset(sample, 0, sizeof(*sample));
            sample->offset = offset;
            sample->size = size;
            offset += size;
            ++sample_index;
        }
    }
    return SP_OK;
}

static sp_status auxiliary_prefix(parse_context *context, const mp4_box *box,
                                  uint8_t max_version, size_t *position,
                                  uint8_t *version) {
    uint32_t flags;
    TRY(full_box(context, box, max_version, 1, version, &flags));
    *position = box->payload + 4;
    if (flags != 0) {
        if (box->end - *position < 8) {
            return box_error(context, box, SP_ERR_FORMAT,
                             "truncated auxiliary information type");
        }
        if (read_u32(context->data + *position) != FOURCC('c', 'e', 'n', 'c') ||
            read_u32(context->data + *position + 4) != 0) {
            return box_error(context, box, SP_ERR_UNSUPPORTED,
                             "unsupported auxiliary information type");
        }
        *position += 8;
    }
    return SP_OK;
}

static sp_status parse_auxiliary(parse_context *context, const sample_tables *tables,
                                 uint32_t sample_count, size_t first_iv,
                                 auxiliary_sizes *auxiliary) {
    const mp4_box *saiz = &tables->saiz;
    const mp4_box *saio = &tables->saio;
    uint8_t version;
    size_t position, width;
    uint32_t count;
    uint64_t offset;
    if (!saiz->present && !saio->present) return SP_OK;
    if (!saiz->present || !saio->present) {
        return sp_error_set(context->error, SP_ERR_FORMAT,
                            "MP4 saiz and saio must be present together");
    }
    TRY(auxiliary_prefix(context, saiz, 0, &position, &version));
    if (saiz->end - position < 5) {
        return box_error(context, saiz, SP_ERR_FORMAT, "truncated auxiliary sizes");
    }
    auxiliary->present = 1;
    auxiliary->fixed_size = context->data[position];
    count = read_u32(context->data + position + 1);
    position += 5;
    if (count != sample_count ||
        (auxiliary->fixed_size != 0 && position != saiz->end) ||
        (auxiliary->fixed_size == 0 && count != saiz->end - position)) {
        return box_error(context, saiz, SP_ERR_FORMAT, "auxiliary size count mismatch");
    }
    auxiliary->sizes = position;
    TRY(auxiliary_prefix(context, saio, 1, &position, &version));
    if (saio->end - position < 4) {
        return box_error(context, saio, SP_ERR_FORMAT, "missing auxiliary offset count");
    }
    count = read_u32(context->data + position);
    position += 4;
    width = version == 0 ? 4 : 8;
    if ((size_t)count != (saio->end - position) / width ||
        (saio->end - position) % width != 0) {
        return box_error(context, saio, SP_ERR_FORMAT, "auxiliary offset count mismatch");
    }
    if (count == 0 && sample_count == 0) return SP_OK;
    if (count != 1) {
        return box_error(context, saio, SP_ERR_UNSUPPORTED,
                         "only one contiguous inline auxiliary block is supported");
    }
    offset = width == 8 ? read_u64(context->data + position)
                        : read_u32(context->data + position);
    if (offset != context->moov_offset + first_iv) {
        return box_error(context, saio, SP_ERR_UNSUPPORTED,
                         "auxiliary offset does not reference inline senc");
    }
    return SP_OK;
}

static sp_status senc_header(parse_context *context, const mp4_box *senc,
                             uint32_t sample_count, uint8_t iv_size,
                             uint32_t *flags, size_t *position) {
    uint8_t version;
    size_t minimum_entry;
    if (!senc->present) {
        return sp_error_set(context->error, SP_ERR_UNSUPPORTED,
                            "Encrypted MP4 track requires inline senc; external auxiliary data is unsupported");
    }
    TRY(full_box(context, senc, 0, 2, &version, flags));
    if (senc->end - senc->payload < 8) {
        return box_error(context, senc, SP_ERR_FORMAT, "missing encrypted sample count");
    }
    if (read_u32(context->data + senc->payload + 4) != sample_count) {
        return box_error(context, senc, SP_ERR_FORMAT, "encrypted sample count mismatch");
    }
    *position = senc->payload + 8;
    minimum_entry = iv_size + ((*flags & 2) ? 2u : 0u);
    if ((size_t)sample_count > (senc->end - *position) / minimum_entry) {
        return box_error(context, senc, SP_ERR_FORMAT, "truncated sample encryption records");
    }
    return SP_OK;
}

static sp_status parse_senc(parse_context *context, const sample_tables *tables,
                            const protection_info *protection, const table_view *view,
                            sp_sample *samples, uint32_t flags, size_t position,
                            const auxiliary_sizes *auxiliary) {
    const mp4_box *box = &tables->senc;
    uint32_t i;
    for (i = 0; i < view->sample_count; ++i) {
        sp_sample *sample = samples + i;
        size_t start = position;
        size_t subsample_position = 0;
        uint32_t subsample_count = 0, j;
        uint64_t covered = 0, encrypted = sample->size;
        if (box->end - position < protection->iv_size) {
            return box_error(context, box, SP_ERR_FORMAT, "truncated sample IV");
        }
        memcpy(sample->iv, context->data + position, protection->iv_size);
        sample->iv_size = protection->iv_size;
        position += protection->iv_size;
        if ((flags & 2) != 0) {
            if (box->end - position < 2) {
                return box_error(context, box, SP_ERR_FORMAT, "missing subsample count");
            }
            subsample_count = read_u16(context->data + position);
            position += 2;
            if (subsample_count > SP_MAX_SUBSAMPLES - context->subsamples_seen) {
                return box_error(context, box, SP_ERR_RANGE, "subsample limit exceeded");
            }
            context->subsamples_seen += subsample_count;
            if ((size_t)subsample_count > (box->end - position) / 6) {
                return box_error(context, box, SP_ERR_FORMAT, "truncated subsample records");
            }
            subsample_position = position;
            if (subsample_count != 0) encrypted = 0;
            for (j = 0; j < subsample_count; ++j) {
                uint32_t clear_bytes = read_u16(context->data + position);
                uint32_t encrypted_bytes = read_u32(context->data + position + 2);
                covered += (uint64_t)clear_bytes + encrypted_bytes;
                encrypted += encrypted_bytes;
                if (covered > sample->size) {
                    return box_error(context, box, SP_ERR_FORMAT,
                                     "subsample ranges exceed sample size");
                }
                position += 6;
            }
            if (subsample_count != 0 && covered != sample->size) {
                return box_error(context, box, SP_ERR_FORMAT,
                                 "subsample ranges do not cover the sample");
            }
        }
        if (auxiliary->present) {
            uint8_t expected = auxiliary->fixed_size ? auxiliary->fixed_size
                : context->data[auxiliary->sizes + i];
            if (position - start != expected) {
                return box_error(context, &tables->saiz, SP_ERR_FORMAT,
                                 "auxiliary size differs from senc record");
            }
        }
        if (encrypted == 0) {
            sample->iv_size = 0;
        } else if (subsample_count != 0) {
            void *replacement;
            size_t base = context->index->subsample_count;
            TRY(grow_array(context, context->index->subsamples,
                           &context->subsample_capacity, base + subsample_count,
                           sizeof(sp_subsample), SP_MAX_SUBSAMPLES, &replacement));
            context->index->subsamples = (sp_subsample *)replacement;
            sample->subsample_start = (uint32_t)base;
            sample->subsample_count = subsample_count;
            for (j = 0; j < subsample_count; ++j) {
                sp_subsample *subsample = context->index->subsamples + base + j;
                subsample->clear_bytes = read_u16(context->data + subsample_position);
                subsample->encrypted_bytes = read_u32(context->data + subsample_position + 2);
                subsample_position += 6;
            }
            context->index->subsample_count += subsample_count;
        }
    }
    if (position != box->end) {
        return box_error(context, box, SP_ERR_FORMAT, "trailing sample encryption data");
    }
    return SP_OK;
}

static sp_status parse_stbl(parse_context *context, const mp4_box *stbl,
                            int *encrypted_track) {
    sample_tables tables = {0};
    protection_info protection = {0};
    table_view view = {0};
    auxiliary_sizes auxiliary = {0};
    uint32_t flags = 0;
    size_t position = 0, base;
    sp_sample *samples = NULL;
    void *replacement;
    TRY(collect_tables(context, stbl, &tables));
    TRY(parse_stsd(context, &tables.stsd, &protection));
    *encrypted_track = protection.encrypted;
    if (!protection.encrypted) {
        if (tables.senc.present) {
            return box_error(context, &tables.senc, SP_ERR_FORMAT,
                             "encryption records exist without a protected sample entry");
        }
    }
    TRY(parse_table_view(context, &tables, &view));
    if (protection.encrypted) {
        TRY(senc_header(context, &tables.senc, view.sample_count, protection.iv_size,
                        &flags, &position));
        TRY(parse_auxiliary(context, &tables, view.sample_count, position, &auxiliary));
    }
    base = context->index->sample_count;
    if (view.sample_count != 0) {
        TRY(grow_array(context, context->index->samples, &context->sample_capacity,
                       base + view.sample_count, sizeof(sp_sample), SP_MAX_SAMPLES,
                       &replacement));
        context->index->samples = (sp_sample *)replacement;
        samples = context->index->samples + base;
    }
    TRY(map_samples(context, &view, samples));
    if (protection.encrypted) {
        TRY(parse_senc(context, &tables, &protection, &view, samples, flags,
                       position, &auxiliary));
    }
    /* Map every track, including fully clear audio/video, and keep all sample
     * spans until the final overlap check. An encrypted range must not alias
     * another track's clear data and modify it in the stream reader. */
    context->index->sample_count += view.sample_count;
    context->samples_seen += view.sample_count;
    if (!protection.encrypted) return SP_OK;
    TRY(add_patch(context, &protection.description, protection.original_format));
    TRY(add_patch(context, &protection.protection, FOURCC('f', 'r', 'e', 'e')));
    TRY(add_patch(context, &tables.senc, FOURCC('f', 'r', 'e', 'e')));
    if (tables.saiz.present) {
        TRY(add_patch(context, &tables.saiz, FOURCC('f', 'r', 'e', 'e')));
        TRY(add_patch(context, &tables.saio, FOURCC('f', 'r', 'e', 'e')));
    }
    return SP_OK;
}

static sp_status check_data_reference(parse_context *context, const mp4_box *dinf) {
    mp4_box dref = {0};
    size_t position = dinf->payload;
    uint8_t version;
    uint32_t flags, count, i;
    while (position < dinf->end) {
        mp4_box child;
        TRY(next_box(context, &position, dinf->end, &child));
        if (child.type == FOURCC('d', 'r', 'e', 'f')) {
            TRY(unique_box(context, &dref, &child));
        }
    }
    if (!dref.present) {
        return box_error(context, dinf, SP_ERR_FORMAT, "missing data reference table");
    }
    TRY(full_box(context, &dref, 0, 0, &version, &flags));
    if (dref.end - dref.payload < 8) {
        return box_error(context, &dref, SP_ERR_FORMAT, "missing data reference count");
    }
    count = read_u32(context->data + dref.payload + 4);
    position = dref.payload + 8;
    if (count == 0 || count > (dref.end - position) / 8) {
        return box_error(context, &dref, SP_ERR_FORMAT, "invalid data reference count");
    }
    for (i = 0; i < count; ++i) {
        mp4_box entry;
        TRY(next_box(context, &position, dref.end, &entry));
        if (i == 0) {
            if (entry.type != FOURCC('u', 'r', 'l', ' ')) {
                return box_error(context, &entry, SP_ERR_UNSUPPORTED,
                                 "only self-contained data references are supported");
            }
            TRY(full_box(context, &entry, 0, 1, &version, &flags));
            if (flags != 1 || entry.end - entry.payload != 4) {
                return box_error(context, &entry, SP_ERR_UNSUPPORTED,
                                 "external sample data is not supported");
            }
        }
    }
    if (position != dref.end) {
        return box_error(context, &dref, SP_ERR_FORMAT, "trailing data reference entries");
    }
    return SP_OK;
}

static sp_status parse_track_container(parse_context *context, const mp4_box *container,
                                       uint32_t required_type) {
    size_t position = container->payload;
    mp4_box required = {0}, dinf = {0};
    int encrypted_track = 0;
    while (position < container->end) {
        mp4_box child;
        TRY(next_box(context, &position, container->end, &child));
        if (child.type == required_type) {
            TRY(unique_box(context, &required, &child));
        } else if (required_type == FOURCC('s', 't', 'b', 'l') &&
                   child.type == FOURCC('d', 'i', 'n', 'f')) {
            TRY(unique_box(context, &dinf, &child));
        }
    }
    if (!required.present) {
        return box_error(context, container, SP_ERR_FORMAT,
                         "missing required track container");
    }
    if (required_type == FOURCC('m', 'd', 'i', 'a')) {
        return parse_track_container(context, &required, FOURCC('m', 'i', 'n', 'f'));
    }
    if (required_type == FOURCC('m', 'i', 'n', 'f')) {
        return parse_track_container(context, &required, FOURCC('s', 't', 'b', 'l'));
    }
    TRY(parse_stbl(context, &required, &encrypted_track));
    if (encrypted_track && dinf.present) TRY(check_data_reference(context, &dinf));
    return SP_OK;
}

static int compare_samples(const void *left, const void *right) {
    const sp_sample *a = (const sp_sample *)left;
    const sp_sample *b = (const sp_sample *)right;
    return a->offset < b->offset ? -1 : a->offset > b->offset ? 1 : 0;
}

static sp_status remove_pssh(parse_context *context, const mp4_box *box) {
    uint8_t version;
    uint32_t flags;
    size_t position;
    TRY(full_box(context, box, 1, 0, &version, &flags));
    if (box->end - box->payload < 24) {
        return box_error(context, box, SP_ERR_FORMAT, "truncated DRM system header");
    }
    position = box->payload + 20; /* FullBox header and 16-byte system ID. */
    if (version == 1) {
        uint32_t count = read_u32(context->data + position);
        position += 4;
        if ((size_t)count > (box->end - position) / 16) {
            return box_error(context, box, SP_ERR_FORMAT,
                             "DRM key ID count exceeds box");
        }
        position += (size_t)count * 16;
    }
    if (box->end - position < 4 ||
        read_u32(context->data + position) != box->end - position - 4) {
        return box_error(context, box, SP_ERR_FORMAT, "DRM data size does not match box");
    }
    /* A clear sample entry with live pssh can still cause a player to request
     * a DRM session. Keep its bytes/length, but stop advertising init data. */
    return add_patch(context, box, FOURCC('f', 'r', 'e', 'e'));
}

void sp_mp4_index_dispose(sp_mp4_index *index) {
    if (!index) return;
    free(index->samples);
    free(index->subsamples);
    memset(index, 0, sizeof(*index));
}

sp_status sp_mp4_parse(uint8_t *moov, size_t length, uint64_t moov_offset,
                       uint64_t file_size, sp_mp4_index *index, sp_error *error) {
    parse_context context;
    mp4_box movie;
    size_t position = 0, i;
    sp_status status;
    if (!moov || !index || index->samples || index->subsamples ||
        index->sample_count || index->subsample_count) {
        return sp_error_set(error, SP_ERR_ARGUMENT,
                            "MP4 parser requires a buffer and an empty index");
    }
    if (length > SP_MAX_MOOV_BYTES) {
        return sp_error_set(error, SP_ERR_RANGE, "MP4 moov exceeds metadata limit");
    }
    if (length < 8 || moov_offset > file_size || length > file_size - moov_offset) {
        return sp_error_set(error, SP_ERR_FORMAT, "Invalid MP4 moov file range");
    }
    memset(&context, 0, sizeof(context));
    context.data = moov;
    context.length = length;
    context.moov_offset = moov_offset;
    context.file_size = file_size;
    context.index = index;
    context.error = error;
    if (error) {
        error->code = SP_OK;
        error->message[0] = 0;
    }
    status = next_box(&context, &position, length, &movie);
    if (status != SP_OK) goto fail;
    if (movie.type != FOURCC('m', 'o', 'o', 'v') || position != length ||
        (read_u32(moov) == 0 && length != file_size - moov_offset)) {
        status = sp_error_set(error, SP_ERR_FORMAT,
                              "MP4 parser requires one complete moov box");
        goto fail;
    }
    position = movie.payload;
    while (position < movie.end) {
        mp4_box child;
        status = next_box(&context, &position, movie.end, &child);
        if (status != SP_OK) goto fail;
        if (child.type == FOURCC('m', 'v', 'e', 'x') ||
            child.type == FOURCC('m', 'o', 'o', 'f')) {
            status = box_error(&context, &child, SP_ERR_UNSUPPORTED,
                                "fragmented MP4 is not supported");
            goto fail;
        }
        if (child.type == FOURCC('t', 'r', 'a', 'k')) {
            status = parse_track_container(&context, &child, FOURCC('m', 'd', 'i', 'a'));
            if (status != SP_OK) goto fail;
        } else if (child.type == FOURCC('p', 's', 's', 'h')) {
            status = remove_pssh(&context, &child);
            if (status != SP_OK) goto fail;
        }
    }
    if (index->sample_count > 1) {
        qsort(index->samples, index->sample_count, sizeof(sp_sample), compare_samples);
    }
    {
        uint64_t previous_end = 0;
        int have_previous = 0;
        size_t retained = 0;
        for (i = 0; i < index->sample_count; ++i) {
            sp_sample *sample = index->samples + i;
            if (sample->size == 0) continue;
            if (have_previous && sample->offset < previous_end) {
                status = sp_error_set(error, SP_ERR_FORMAT,
                                      "MP4 sample ranges overlap");
                goto fail;
            }
            previous_end = sample->offset + sample->size;
            have_previous = 1;
            if (sample->iv_size != 0) {
                if (retained != i) index->samples[retained] = *sample;
                ++retained;
            }
        }
        index->sample_count = retained;
    }
    for (i = 0; i < context.patch_count; ++i) {
        write_u32(moov + context.patches[i].offset, context.patches[i].type);
    }
    free(context.patches);
    return SP_OK;

fail:
    free(context.patches);
    sp_mp4_index_dispose(index);
    return status;
}
