#include "sp_crypto.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "CHECK failed at line %d: %s\n", __LINE__, #condition); return 1; \
} } while (0)

static const uint8_t key[16] = {
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
};

typedef struct {
    uint8_t *data;
    size_t length;
    size_t max_read;
    unsigned reads;
    unsigned cancels;
    unsigned closes;
    int opening;
    size_t payload_during_open;
    int fail_read;
    int extra_read;
    size_t media_start[16];
    size_t media_end[16];
    size_t media_count;
} reader;

static uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static uint64_t be64(const uint8_t *p) {
    return ((uint64_t)be32(p) << 32) | be32(p + 4);
}

static uint8_t *load(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) return NULL;
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return NULL; }
    long size = ftell(file);
    if (size < 0 || size > 64 * 1024 * 1024 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    uint8_t *data = malloc((size_t)size + 1);
    if (data == NULL) { fclose(file); return NULL; }
    if (fread(data, 1, (size_t)size, file) != (size_t)size) {
        free(data);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *length = (size_t)size;
    return data;
}

static void find_media(reader *r) {
    size_t offset = 0;
    while (r->length - offset >= 8) {
        uint64_t size = be32(r->data + offset);
        size_t header = 8;
        if (size == 1) {
            if (r->length - offset < 16) return;
            size = be64(r->data + offset + 8);
            header = 16;
        } else if (size == 0) size = r->length - offset;
        if (size < header || size > r->length - offset) return;
        if (memcmp(r->data + offset + 4, "mdat", 4) == 0 && r->media_count < 16) {
            r->media_start[r->media_count] = offset + header;
            r->media_end[r->media_count++] = offset + (size_t)size;
        }
        offset += (size_t)size;
    }
}

static int64_t io_size(void *opaque) { return (int64_t)((reader *)opaque)->length; }

static ptrdiff_t io_read(void *opaque, uint64_t offset, uint8_t *buffer, size_t length) {
    reader *r = opaque;
    ++r->reads;
    if (length > 65536) { fprintf(stderr, "Unbounded network request\n"); return -1; }
    if (r->fail_read) return r->fail_read == 1 ? -1 : 0;
    if (r->extra_read) return (ptrdiff_t)length + 1;
    if (offset >= r->length) return 0;
    if (length > r->length - (size_t)offset) length = r->length - (size_t)offset;
    if (r->max_read != 0 && length > r->max_read) length = r->max_read;
    if (r->opening) {
        for (size_t i = 0; i < r->media_count; ++i) {
            size_t start = (size_t)offset > r->media_start[i] ? (size_t)offset : r->media_start[i];
            size_t end = (size_t)offset + length < r->media_end[i] ? (size_t)offset + length : r->media_end[i];
            if (start < end) r->payload_during_open += end - start;
        }
    }
    memcpy(buffer, r->data + (size_t)offset, length);
    return (ptrdiff_t)length;
}

static void io_cancel(void *opaque) { ++((reader *)opaque)->cancels; }
static void io_close(void *opaque) { ++((reader *)opaque)->closes; }
static sp_io make_io(reader *r) { return (sp_io){r, io_size, io_read, io_cancel, io_close}; }

static int compare(const char *encrypted, const char *expected_path) {
    reader r = {0};
    r.data = load(encrypted, &r.length);
    size_t expected_length = 0;
    uint8_t *expected = load(expected_path, &expected_length);
    CHECK(r.data != NULL && expected != NULL && expected_length == r.length);
    r.max_read = 4093; /* Exercise short network reads during metadata and playback. */
    find_media(&r);
    r.opening = 1;
    sp_io io = make_io(&r);
    sp_error error = {0};
    sp_stream *stream = sp_stream_open(&io, key, &error);
    if (stream == NULL) fprintf(stderr, "Open failed: %d %s\n", error.code, error.message);
    CHECK(stream != NULL);
    CHECK(r.payload_during_open == 0);
    CHECK(sp_stream_size(stream) == (int64_t)r.length);
    CHECK(r.closes == 0);
    r.opening = 0;
    uint8_t buffer[65536];
    const size_t sizes[] = {1, 7, 16, 31, 65536, 32768, 63, 8193};
    size_t position = 0;
    unsigned iteration = 0;
    while (position < expected_length) {
        ptrdiff_t count = sp_stream_read(stream, buffer, sizes[iteration++ % 8], &error);
        if (count <= 0) fprintf(stderr, "Read failed: %d %s\n", error.code, error.message);
        CHECK(count > 0 && (size_t)count <= expected_length - position);
        if (memcmp(buffer, expected + position, (size_t)count) != 0) {
            size_t mismatch = 0;
            while (mismatch < (size_t)count && buffer[mismatch] == expected[position + mismatch]) ++mismatch;
            fprintf(stderr, "Plaintext mismatch at offset %zu\n", position + mismatch);
            return 1;
        }
        position += (size_t)count;
    }
    CHECK(sp_stream_read(stream, buffer, 1, &error) == 0);
    CHECK(sp_stream_seek(stream, -1, &error) < 0 && error.code == SP_ERR_RANGE);
    CHECK(sp_stream_seek(stream, INT64_MAX, &error) < 0 && error.code == SP_ERR_RANGE);
    CHECK(sp_stream_read(stream, buffer, 1, &error) == 0); /* Failed seeks preserve position. */
    CHECK(sp_stream_read(stream, NULL, 0, &error) == 0);
    CHECK(sp_stream_read(stream, NULL, 1, &error) < 0 && error.code == SP_ERR_ARGUMENT);

    uint32_t random = 0x517cc1b7;
    for (unsigned i = 0; i < 600; ++i) {
        random = random * 1664525u + 1013904223u;
        size_t start = random % (expected_length + 1);
        CHECK(sp_stream_seek(stream, (int64_t)start, &error) == (int64_t)start);
        random = random * 1664525u + 1013904223u;
        size_t length = 1 + random % 32769;
        if (length > expected_length - start) length = expected_length - start;
        for (size_t done = 0; done < length;) {
            ptrdiff_t count = sp_stream_read(stream, buffer, length - done, &error);
            CHECK(count > 0 && (size_t)count <= length - done);
            CHECK(memcmp(buffer, expected + start + done, (size_t)count) == 0);
            done += (size_t)count;
        }
    }
    CHECK(r.cancels > 0);
    CHECK(r.media_count > 0);
    size_t payload = r.media_start[0];
    for (int failure = 1; failure <= 3; ++failure) {
        CHECK(sp_stream_seek(stream, (int64_t)payload, &error) == (int64_t)payload);
        r.fail_read = failure <= 2 ? failure : 0;
        r.extra_read = failure == 3;
        CHECK(sp_stream_read(stream, buffer, 7, &error) < 0 && error.code == SP_ERR_IO);
        r.fail_read = 0;
        r.extra_read = 0;
        CHECK(sp_stream_read(stream, buffer, 7, &error) == 7);
        CHECK(memcmp(buffer, expected + payload, 7) == 0);
    }
    unsigned reads = r.reads;
    sp_stream_cancel(stream);
    CHECK(sp_stream_read(stream, buffer, 1, &error) < 0 && error.code == SP_ERR_CANCELLED);
    CHECK(sp_stream_seek(stream, 0, &error) < 0 && error.code == SP_ERR_CANCELLED);
    CHECK(r.reads == reads);
    sp_stream_close(stream);
    CHECK(r.closes == 1);
    free(expected);
    free(r.data);
    puts("PASS sequential, 600 seeks, bounded reads, no initial payload, errors and cancellation");
    return 0;
}

static int reject(const char *path) {
    reader r = {0};
    r.data = load(path, &r.length);
    CHECK(r.data != NULL);
    sp_io io = make_io(&r);
    sp_error error = {0};
    sp_stream *stream = sp_stream_open(&io, key, &error);
    if (stream != NULL) {
        sp_stream_close(stream);
        fprintf(stderr, "Malformed/unsupported MP4 was accepted\n");
        free(r.data);
        return 1;
    }
    CHECK(error.code < 0 && error.message[0] != '\0');
    CHECK(r.closes == 0); /* An unsuccessful open does not take ownership. */
    printf("REJECT %d %s\n", error.code, error.message);
    free(r.data);
    return 0;
}

static int decrypt(const char *path, const char *output) {
    reader r = {0};
    r.data = load(path, &r.length);
    CHECK(r.data != NULL);
    sp_io io = make_io(&r);
    sp_error error = {0};
    sp_stream *stream = sp_stream_open(&io, key, &error);
    if (stream == NULL) fprintf(stderr, "Open failed: %d %s\n", error.code, error.message);
    CHECK(stream != NULL);
    FILE *file = fopen(output, "wb");
    CHECK(file != NULL);
    uint8_t buffer[65536];
    size_t written = 0;
    for (;;) {
        ptrdiff_t count = sp_stream_read(stream, buffer, sizeof(buffer), &error);
        CHECK(count >= 0);
        if (count == 0) break;
        CHECK(fwrite(buffer, 1, (size_t)count, file) == (size_t)count);
        written += (size_t)count;
    }
    CHECK(written == r.length && fclose(file) == 0);
    sp_stream_close(stream);
    free(r.data);
    return 0;
}

static int mutate(const char *path) {
    size_t length = 0;
    uint8_t *original = load(path, &length);
    CHECK(original != NULL && length > 32);
    uint8_t *copy = malloc(length);
    CHECK(copy != NULL);
    uint32_t random = 0x174937;
    for (unsigned iteration = 0; iteration < 4000; ++iteration) {
        memcpy(copy, original, length);
        for (unsigned j = 0; j < 1 + iteration % 5; ++j) {
            random = random * 1664525u + 1013904223u;
            size_t position = random % length;
            random = random * 1664525u + 1013904223u;
            copy[position] ^= (uint8_t)(1 + random % 255);
        }
        reader r = {0};
        r.data = copy;
        r.length = iteration % 11 == 0 ? random % length : length;
        sp_io io = make_io(&r);
        sp_error error = {0};
        sp_stream *stream = sp_stream_open(&io, key, &error);
        if (stream != NULL) {
            uint8_t buffer[113];
            (void)sp_stream_seek(stream, (int64_t)(random % r.length), &error);
            (void)sp_stream_read(stream, buffer, sizeof(buffer), &error);
            sp_stream_close(stream);
            CHECK(r.closes == 1);
        } else CHECK(error.code < 0 && r.closes == 0);
    }
    free(copy);
    free(original);
    puts("PASS 4000 deterministic malformed/truncated mutations");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "compare") == 0) return compare(argv[2], argv[3]);
    if (argc == 4 && strcmp(argv[1], "decrypt") == 0) return decrypt(argv[2], argv[3]);
    if (argc == 3 && strcmp(argv[1], "reject") == 0) return reject(argv[2]);
    if (argc == 3 && strcmp(argv[1], "mutate") == 0) return mutate(argv[2]);
    fprintf(stderr, "Usage: stream_driver compare|decrypt input output; reject|mutate input\n");
    return 2;
}
