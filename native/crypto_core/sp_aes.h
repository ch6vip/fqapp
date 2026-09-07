#ifndef SP_AES_H
#define SP_AES_H

#include <stddef.h>
#include <stdint.h>

/* Implementation owns the private expanded AES-128 key layout. */
typedef struct {
    uint8_t round_key[176];
} sp_aes;

void sp_aes_init(sp_aes *aes, const uint8_t key[16]);
/* Offset counts encrypted bytes within a sample, excluding clear subsamples.
 * IV is 8 or 16 bytes; an 8-byte IV is padded with eight zero counter bytes. */
void sp_aes_ctr_xor(const sp_aes *aes, const uint8_t *iv, size_t iv_size,
                    uint64_t encrypted_offset, uint8_t *buffer, size_t length);
void sp_aes_clear(sp_aes *aes);

#endif
