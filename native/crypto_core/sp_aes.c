#include "sp_aes.h"

#include <string.h>

/* These must match the definitions used to compile the vendored aes.c. */
#ifndef CBC
#define CBC 0
#endif
#ifndef CTR
#define CTR 0
#endif
#ifndef ECB
#define ECB 1
#endif
#include "../third_party/tiny_aes/aes.h"

#if CBC != 0 || CTR != 0 || ECB != 1 || AES_KEYLEN != 16 || AES_keyExpSize != 176
#error "sp_aes requires tiny-AES-c configured for AES-128 ECB only"
#endif

static void secure_clear(void *memory, size_t length) {
    volatile uint8_t *bytes = (volatile uint8_t *)memory;
    while (length != 0) {
        *bytes++ = 0;
        --length;
    }
}

/* Add a block offset to the entire 128-bit, big-endian counter. */
static void counter_add(uint8_t counter[16], uint64_t blocks) {
    size_t index = 16;
    while (index != 0) {
        uint64_t sum;
        --index;
        sum = (uint64_t)counter[index] + (blocks & UINT64_C(255));
        counter[index] = (uint8_t)sum;
        blocks = (blocks >> 8) + (sum >> 8);
    }
}

static void counter_increment(uint8_t counter[16]) {
    size_t index = 16;
    while (index != 0) {
        --index;
        counter[index] = (uint8_t)(counter[index] + 1U);
        if (counter[index] != 0) {
            break;
        }
    }
}

void sp_aes_init(sp_aes *aes, const uint8_t key[16]) {
    struct AES_ctx context;
    if (aes == NULL) {
        return;
    }
    if (key == NULL) {
        secure_clear(aes, sizeof(*aes));
        return;
    }
    AES_init_ctx(&context, key);
    memcpy(aes->round_key, context.RoundKey, sizeof(aes->round_key));
    secure_clear(&context, sizeof(context));
}

void sp_aes_ctr_xor(const sp_aes *aes, const uint8_t *iv, size_t iv_size,
                    uint64_t encrypted_offset, uint8_t *buffer, size_t length) {
    struct AES_ctx context;
    uint8_t counter[16] = {0};
    uint8_t keystream[16];
    size_t position = (size_t)(encrypted_offset & UINT64_C(15));

    if (length == 0) {
        return;
    }
    /* The stream/parser API reports invalid arguments to its caller. */
    if (aes == NULL || iv == NULL || buffer == NULL ||
        (iv_size != 8 && iv_size != 16)) {
        return;
    }

    memcpy(context.RoundKey, aes->round_key, sizeof(aes->round_key));
    memcpy(counter, iv, iv_size);
    counter_add(counter, encrypted_offset >> 4);

    while (length != 0) {
        size_t count = 16 - position;
        size_t index;
        if (count > length) {
            count = length;
        }
        memcpy(keystream, counter, sizeof(keystream));
        AES_ECB_encrypt(&context, keystream);
        for (index = 0; index < count; ++index) {
            buffer[index] ^= keystream[position + index];
        }
        buffer += count;
        length -= count;
        position = 0;
        counter_increment(counter);
    }

    secure_clear(&context, sizeof(context));
    secure_clear(counter, sizeof(counter));
    secure_clear(keystream, sizeof(keystream));
}

void sp_aes_clear(sp_aes *aes) {
    if (aes != NULL) {
        secure_clear(aes, sizeof(*aes));
    }
}
