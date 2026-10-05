#ifndef SP_CRYPTO_H
#define SP_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SP_OK = 0,
    SP_ERR_IO = -1,
    SP_ERR_FORMAT = -2,
    SP_ERR_MEMORY = -3,
    SP_ERR_CANCELLED = -4,
    SP_ERR_ARGUMENT = -5,
    SP_ERR_UNSUPPORTED = -6,
    SP_ERR_RANGE = -7
} sp_status;

typedef struct {
    sp_status code;
    char message[192];
} sp_error;

sp_status sp_error_set(sp_error *error, sp_status code, const char *format, ...);

/* A successful open transfers the I/O context to the stream. On open failure,
 * the caller still owns it. read_at may return a short positive read, zero at
 * EOF, or -1 on error. cancel interrupts the current request but allows a later
 * read_at (after seek) to start another request. It must be safe to call while
 * read_at is blocked. close runs once, after all stream operations have ended. */
typedef struct {
    void *user;
    int64_t (*size)(void *user);
    ptrdiff_t (*read_at)(void *user, uint64_t offset, uint8_t *buffer, size_t length);
    void (*cancel)(void *user);
    void (*close)(void *user);
} sp_io;

typedef struct sp_stream sp_stream;

/* Streams are serialized by the caller, except cancel, which is thread safe.
 * The key is the 16-byte CENC AES key already resolved by the Rust core. */
sp_stream *sp_stream_open(const sp_io *io, const uint8_t key[16], sp_error *error);
ptrdiff_t sp_stream_read(sp_stream *stream, uint8_t *buffer, size_t length, sp_error *error);
int64_t sp_stream_seek(sp_stream *stream, int64_t position, sp_error *error);
int64_t sp_stream_size(const sp_stream *stream);
void sp_stream_cancel(sp_stream *stream);
void sp_stream_close(sp_stream *stream);

#ifdef __cplusplus
}
#endif
#endif
