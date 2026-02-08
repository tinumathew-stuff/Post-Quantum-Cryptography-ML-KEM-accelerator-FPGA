#ifndef C_REF_COMMON_H
#define C_REF_COMMON_H

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

//==============================================================================
// Utility: Load raw hex bytes from vector files
// Supports searching in standard relative directories
//==============================================================================
static inline int load_hex_file(const char *filename, uint8_t *buf, size_t len) {
    const char *prefixes[] = {
        "",
        "../vectors/",
        "vectors/",
        "usertest/vectors/",
        "./vectors/",
        NULL
    };

    FILE *f = NULL;
    char path[512];

    for (int i = 0; prefixes[i] != NULL; i++) {
        snprintf(path, sizeof(path), "%s%s", prefixes[i], filename);
        f = fopen(path, "r");
        if (f) {
            break;
        }
    }

    if (!f) {
        fprintf(stderr, "Error: Unable to locate and open hex vector file: %s\n", filename);
        return 0;
    }

    size_t count = 0;
    unsigned int byte_val;
    while (count < len && fscanf(f, "%02x", &byte_val) == 1) {
        buf[count++] = (uint8_t)byte_val;
    }

    fclose(f);

    if (count != len) {
        fprintf(stderr, "Error: Read %zu bytes from %s, expected %zu bytes\n", count, path, len);
        return 0;
    }

    return 1;
}

//==============================================================================
// Utility: Print byte array as lowercase continuous hex string
//==============================================================================
static inline void print_hex_bytes(const char *tag, const uint8_t *buf, size_t len) {
    printf("%s", tag);
    for (size_t i = 0; i < len; i++) {
        printf("%02x", buf[i]);
    }
    printf("\n");
}

//==============================================================================
// Standard NIST FIPS 202 Keccak-f[1600] Permutation and SHA-3 Primitives
//==============================================================================
static const uint64_t KECCAK_ROUND_CONSTANTS[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL,
    0x8000000080008000ULL, 0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL, 0x000000000000008aULL,
    0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL,
    0x8000000000008003ULL, 0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL, 0x8000000080008081ULL,
    0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL
};

static const unsigned int KECCAK_ROTATION_OFFSETS[25] = {
     0,  1, 62, 28, 27,
    36, 44,  6, 55, 20,
     3, 10, 43, 25, 39,
    41, 45, 15, 21,  8,
    18,  2, 61, 56, 14
};

static const unsigned int KECCAK_PI_INDEX[25] = {
     0, 10, 20,  5, 15,
    16,  1, 11, 21,  6,
     7, 17,  2, 12, 22,
    23,  8, 18,  3, 13,
    14, 24,  9, 19,  4
};

#define ROTL64(x, s) (((x) << (s)) | ((x) >> (64 - (s))))

static inline void keccak_f1600_permute(uint64_t state[25]) {
    for (int round = 0; round < 24; round++) {
        // Theta step
        uint64_t c[5];
        for (int i = 0; i < 5; i++) {
            c[i] = state[i] ^ state[i + 5] ^ state[i + 10] ^ state[i + 15] ^ state[i + 20];
        }
        for (int i = 0; i < 5; i++) {
            uint64_t d = c[(i + 4) % 5] ^ ROTL64(c[(i + 1) % 5], 1);
            for (int j = 0; j < 25; j += 5) {
                state[i + j] ^= d;
            }
        }

        // Rho and Pi steps
        uint64_t b[25];
        for (int i = 0; i < 25; i++) {
            b[KECCAK_PI_INDEX[i]] = ROTL64(state[i], KECCAK_ROTATION_OFFSETS[i]);
        }

        // Chi step
        for (int j = 0; j < 25; j += 5) {
            for (int i = 0; i < 5; i++) {
                state[j + i] = b[j + i] ^ ((~b[j + ((i + 1) % 5)]) & b[j + ((i + 2) % 5)]);
            }
        }

        // Iota step
        state[0] ^= KECCAK_ROUND_CONSTANTS[round];
    }
}

// Generic sponge function for SHA-3 and SHAKE
static inline void keccak_sponge(const uint8_t *in, size_t in_len,
                                 uint8_t delim, size_t rate,
                                 uint8_t *out, size_t out_len) {
    uint64_t state[25];
    memset(state, 0, sizeof(state));

    uint8_t *state_bytes = (uint8_t *)state;
    size_t rate_bytes = rate;

    // Absorb full blocks
    while (in_len >= rate_bytes) {
        for (size_t i = 0; i < rate_bytes; i++) {
            state_bytes[i] ^= in[i];
        }
        keccak_f1600_permute(state);
        in += rate_bytes;
        in_len -= rate_bytes;
    }

    // Absorb final partial block with padding
    for (size_t i = 0; i < in_len; i++) {
        state_bytes[i] ^= in[i];
    }
    state_bytes[in_len] ^= delim;
    state_bytes[rate_bytes - 1] ^= 0x80;

    keccak_f1600_permute(state);

    // Squeeze output blocks
    while (out_len > 0) {
        size_t block_len = out_len < rate_bytes ? out_len : rate_bytes;
        memcpy(out, state_bytes, block_len);
        out += block_len;
        out_len -= block_len;
        if (out_len > 0) {
            keccak_f1600_permute(state);
        }
    }
}

// Standard SHA3-256 (rate = 136 bytes, delim = 0x06)
static inline void sha3_256(const uint8_t *in, size_t in_len, uint8_t out[32]) {
    keccak_sponge(in, in_len, 0x06, 136, out, 32);
}

// Standard SHA3-512 (rate = 72 bytes, delim = 0x06)
static inline void sha3_512(const uint8_t *in, size_t in_len, uint8_t out[64]) {
    keccak_sponge(in, in_len, 0x06, 72, out, 64);
}

// Standard SHAKE128 (rate = 168 bytes, delim = 0x1f)
static inline void shake128(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    keccak_sponge(in, in_len, 0x1f, 168, out, out_len);
}

// Standard SHAKE256 (rate = 136 bytes, delim = 0x1f)
static inline void shake256(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    keccak_sponge(in, in_len, 0x1f, 136, out, out_len);
}

#endif // C_REF_COMMON_H
