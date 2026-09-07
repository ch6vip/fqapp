/* AES test driver. The expected ciphertext below is NIST SP 800-38A F.5.1;
 * additional CTR results are checked by Node's independent crypto provider. */
#include "../crypto_core/sp_aes.h"

#include <stdio.h>
#include <string.h>

#define MAX_VECTOR_BYTES 8192
#define GUARD_BYTES 16

static int hex_digit(char character) {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    if (character >= 'A' && character <= 'F') {
        return character - 'A' + 10;
    }
    return -1;
}

static size_t decode_hex(const char *text, uint8_t *output, size_t capacity) {
    size_t size = strlen(text);
    size_t index;
    if ((size & 1U) != 0 || size / 2 > capacity) {
        return SIZE_MAX;
    }
    for (index = 0; index < size / 2; ++index) {
        int high = hex_digit(text[index * 2]);
        int low = hex_digit(text[index * 2 + 1]);
        if (high < 0 || low < 0) {
            return SIZE_MAX;
        }
        output[index] = (uint8_t)(high * 16 + low);
    }
    return size / 2;
}

static int decode_offset(const char *text, uint64_t *output) {
    size_t size = strlen(text);
    size_t index;
    uint64_t value = 0;
    if (size == 0 || size > 16) {
        return 0;
    }
    for (index = 0; index < size; ++index) {
        int digit = hex_digit(text[index]);
        if (digit < 0) {
            return 0;
        }
        value = (value << 4) | (uint64_t)digit;
    }
    *output = value;
    return 1;
}

static int nist_and_lifecycle_test(void) {
    static const uint8_t key[16] = {
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c
    };
    static const uint8_t iv[16] = {
        0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7,
        0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff
    };
    static const uint8_t plaintext[64] = {
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
        0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c,
        0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
        0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11,
        0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef,
        0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17,
        0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10
    };
    static const uint8_t ciphertext[64] = {
        0x87, 0x4d, 0x61, 0x91, 0xb6, 0x20, 0xe3, 0x26,
        0x1b, 0xef, 0x68, 0x64, 0x99, 0x0d, 0xb6, 0xce,
        0x98, 0x06, 0xf6, 0x6b, 0x79, 0x70, 0xfd, 0xff,
        0x86, 0x17, 0x18, 0x7b, 0xb9, 0xff, 0xfd, 0xff,
        0x5a, 0xe4, 0xdf, 0x3e, 0xdb, 0xd5, 0xd3, 0x5e,
        0x5b, 0x4f, 0x09, 0x02, 0x0d, 0xb0, 0x3e, 0xab,
        0x1e, 0x03, 0x1d, 0xda, 0x2f, 0xbe, 0x03, 0xd1,
        0x79, 0x21, 0x70, 0xa0, 0xf3, 0x00, 0x9c, 0xee
    };
    sp_aes aes;
    sp_aes original;
    uint8_t buffer[sizeof(plaintext)];
    size_t index;

    sp_aes_init(&aes, key);
    original = aes;
    memcpy(buffer, plaintext, sizeof(buffer));
    sp_aes_ctr_xor(&aes, iv, sizeof(iv), 0, buffer, sizeof(buffer));
    if (memcmp(buffer, ciphertext, sizeof(buffer)) != 0) {
        fputs("NIST AES-128 CTR encryption failed\n", stderr);
        return 0;
    }
    sp_aes_ctr_xor(&aes, iv, sizeof(iv), 0, buffer, sizeof(buffer));
    if (memcmp(buffer, plaintext, sizeof(buffer)) != 0) {
        fputs("NIST AES-128 CTR decryption failed\n", stderr);
        return 0;
    }
    memcpy(buffer, ciphertext, sizeof(buffer));
    sp_aes_ctr_xor(&aes, iv, sizeof(iv), 17, buffer + 17, 29);
    if (memcmp(buffer, ciphertext, 17) != 0 ||
        memcmp(buffer + 17, plaintext + 17, 29) != 0 ||
        memcmp(buffer + 46, ciphertext + 46, sizeof(buffer) - 46) != 0) {
        fputs("NIST unaligned subrange decryption failed\n", stderr);
        return 0;
    }
    sp_aes_ctr_xor(&aes, NULL, 0, 0, NULL, 0);
    if (memcmp(&aes, &original, sizeof(aes)) != 0) {
        fputs("CTR read mutated the expanded key\n", stderr);
        return 0;
    }
    sp_aes_clear(&aes);
    sp_aes_clear(&original);
    for (index = 0; index < sizeof(aes.round_key); ++index) {
        if (aes.round_key[index] != 0 || original.round_key[index] != 0) {
            fputs("Expanded AES key was not cleared\n", stderr);
            return 0;
        }
    }
    return 1;
}

int main(void) {
    char line[MAX_VECTOR_BYTES * 2 + 128];
    uint8_t buffer[MAX_VECTOR_BYTES + GUARD_BYTES * 2];
    size_t line_number = 0;
    if (!nist_and_lifecycle_test()) {
        return 1;
    }
    puts("SELFTEST OK");

    /* One vector per line: key_hex iv_hex encrypted_offset_hex input_hex.
     * A dash encodes an empty input. One output hex string follows per line. */
    while (fgets(line, sizeof(line), stdin) != NULL) {
        uint8_t key[16];
        uint8_t iv[16];
        uint64_t offset;
        size_t iv_size;
        size_t size;
        size_t index;
        char *key_hex = strtok(line, " \t\r\n");
        char *iv_hex = strtok(NULL, " \t\r\n");
        char *offset_hex = strtok(NULL, " \t\r\n");
        char *input_hex = strtok(NULL, " \t\r\n");
        char *extra = strtok(NULL, " \t\r\n");
        sp_aes aes;
        ++line_number;
        if (key_hex == NULL || iv_hex == NULL || offset_hex == NULL ||
            input_hex == NULL || extra != NULL ||
            decode_hex(key_hex, key, sizeof(key)) != sizeof(key) ||
            !decode_offset(offset_hex, &offset)) {
            fprintf(stderr, "Invalid vector fields at line %zu\n", line_number);
            return 2;
        }
        iv_size = decode_hex(iv_hex, iv, sizeof(iv));
        memset(buffer, 0xa5, sizeof(buffer));
        size = strcmp(input_hex, "-") == 0 ? 0 :
            decode_hex(input_hex, buffer + GUARD_BYTES, MAX_VECTOR_BYTES);
        if ((iv_size != 8 && iv_size != 16) || size == SIZE_MAX) {
            fprintf(stderr, "Invalid IV or payload at line %zu\n", line_number);
            return 2;
        }

        sp_aes_init(&aes, key);
        sp_aes_ctr_xor(&aes, iv, iv_size, offset, buffer + GUARD_BYTES, size);
        sp_aes_clear(&aes);
        for (index = 0; index < GUARD_BYTES; ++index) {
            if (buffer[index] != 0xa5 ||
                buffer[GUARD_BYTES + size + index] != 0xa5) {
                fprintf(stderr, "CTR wrote outside its buffer at line %zu\n", line_number);
                return 3;
            }
        }
        if (size == 0) {
            putchar('-');
        }
        for (index = 0; index < size; ++index) {
            printf("%02x", (unsigned int)buffer[GUARD_BYTES + index]);
        }
        putchar('\n');
    }
    if (ferror(stdin)) {
        fputs("Failed to read test vectors\n", stderr);
        return 2;
    }
    return 0;
}
