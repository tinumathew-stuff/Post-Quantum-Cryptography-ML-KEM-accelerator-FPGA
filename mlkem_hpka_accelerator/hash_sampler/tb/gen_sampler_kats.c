#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define main reference_main
#include "../../../stockham4butterfly/roundtripstockham.c"
#undef main

static int write_coefficients(const char *path, const int16_t *coeff, unsigned n) {
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    for (unsigned i = 0; i < n; i++) {
        int value = coeff[i];
        if (value < 0) value += Q;
        fprintf(f, "%03x\n", (unsigned)value);
    }
    return fclose(f) == 0;
}

static int write_bytes(const char *path, const uint8_t *bytes, unsigned n) {
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    for (unsigned i = 0; i < n; i++) {
        fprintf(f, "%02x\n", bytes[i]);
    }
    return fclose(f) == 0;
}

static void shake256_hash(const uint8_t *in, size_t inlen, uint8_t out[32]) {
    keccak_ctx_t xof;
    shake256_init(&xof);
    shake256_absorb(&xof, in, inlen);
    shake256_finalize(&xof);
    shake256_squeeze(&xof, out, 32);
}

int main(void) {
    const uint8_t seed[32] = {
        0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef,
        0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef,
        0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef,
        0x01,0x23,0x45,0x67,0x89,0xab,0xcd,0xef
    };
    int16_t matrix[4*4*N];
    int16_t vector[4*N];
    uint8_t digest[64];
    uint8_t message[1600];
    const unsigned lengths[] = {0,3,32,71,72,73,135,136,137,272,800,1120,1600};
    char path[96];

    printf("Generating Hash & Sampler KATs from stockham4butterfly/roundtripstockham.c...\n");

    sha3_256(seed, 32, digest);
    if (!write_bytes("hash256.hex", digest, 32)) return 1;
    sha3_512(seed, 32, digest);
    if (!write_bytes("hash512.hex", digest, 64)) return 1;

    for (unsigned i = 0; i < 1600; i++) message[i] = seed[i % 32];

    for (unsigned i = 0; i < sizeof(lengths)/sizeof(lengths[0]); i++) {
        unsigned len = lengths[i];
        if (len <= 272) {
            sha3_256(message, len, digest);
            snprintf(path, sizeof(path), "hash256_len%u.hex", len);
            if (!write_bytes(path, digest, 32)) return 1;

            sha3_512(message, len, digest);
            snprintf(path, sizeof(path), "hash512_len%u.hex", len);
            if (!write_bytes(path, digest, 64)) return 1;
        }

        shake256_hash(message, len, digest);
        snprintf(path, sizeof(path), "shake256_len%u.hex", len);
        if (!write_bytes(path, digest, 32)) return 1;
    }

    for (unsigned k = 2; k <= 4; k++) {
        for (unsigned transpose = 0; transpose < 2; transpose++) {
            generate_matrix(matrix, k, seed, (int)transpose);
            snprintf(path, sizeof(path), "matrix_k%u_t%u.hex", k, transpose);
            if (!write_coefficients(path, matrix, k*k*N)) return 1;
        }
        for (unsigned eta = 2; eta <= 3; eta++) {
            generate_vector(vector, k, eta, seed, 4);
            snprintf(path, sizeof(path), "vector_k%u_eta%u.hex", k, eta);
            if (!write_coefficients(path, vector, k*N)) return 1;
            if (k == 4) {
                generate_vector(vector, k, eta, seed, 255);
                snprintf(path, sizeof(path), "vector_k4_eta%u_n255.hex", eta);
                if (!write_coefficients(path, vector, k*N)) return 1;
            }
        }
    }

    // Rejection sampling edge case
    {
        uint8_t candidate_seed[32], matrix_input[34], squeeze[168];
        unsigned found = 0;
        for (unsigned attempt = 0; attempt < 10000 && !found; attempt++) {
            unsigned accepted = 0;
            for (unsigned i = 0; i < 32; i++)
                candidate_seed[i] = (uint8_t)(i*37u + attempt*13u + (attempt>>8));
            memcpy(matrix_input, candidate_seed, 32);
            matrix_input[32] = 0;
            matrix_input[33] = 0;
            keccak_ctx_t xof;
            shake128_init(&xof);
            shake128_absorb(&xof, matrix_input, 34);
            shake128_finalize(&xof);
            for (unsigned block = 0; block < 3; block++) {
                shake128_squeeze(&xof, squeeze, 168);
                for (unsigned off = 0; off < 168; off += 3) {
                    unsigned a = squeeze[off] | ((unsigned)(squeeze[off+1] & 15) << 8);
                    unsigned b = (squeeze[off+1] >> 4) | ((unsigned)squeeze[off+2] << 4);
                    if (a < Q) accepted++;
                    if (b < Q) accepted++;
                }
            }
            if (accepted < 256) {
                found = 1;
                generate_matrix(matrix, 2, candidate_seed, 0);
                if (!write_coefficients("reject_matrix_k2.hex", matrix, 4*N)) return 1;
                if (!write_bytes("reject_seed.hex", candidate_seed, 32)) return 1;
            }
        }
    }

    printf("All Hash & Sampler KATs successfully generated!\n");
    return 0;
}
