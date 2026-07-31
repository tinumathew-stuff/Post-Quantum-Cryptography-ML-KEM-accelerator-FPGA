#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define main reference_main
#include "roundtripstockham.c"
#undef main

static int write_coeffs(const char *name, unsigned k,
                        const int16_t *coeffs, unsigned count) {
    char path[80];
    snprintf(path, sizeof(path), "%s_k%u.hex", name, k);
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    for (unsigned i = 0; i < count; ++i) {
        int value = coeffs[i] % Q;
        if (value < 0) value += Q;
        fprintf(f, "%03x\n", value);
    }
    return fclose(f) == 0;
}

int main(void) {
    uint8_t input[33], digest[64];
    int16_t matrix[MAX_K * MAX_K * N];
    int16_t s[MAX_K * N], e[MAX_K * N];
    for (unsigned i = 0; i < 32; ++i) input[i] = (uint8_t)i;
    for (unsigned k = 2; k <= 4; ++k) {
        input[32] = (uint8_t)k;
        sha3_512(input, sizeof(input), digest);
        generate_matrix(matrix, k, digest, 0);
        generate_vector(s, k, k == 2 ? 3 : 2, digest + 32, 0);
        generate_vector(e, k, k == 2 ? 3 : 2, digest + 32, (uint8_t)k);
        if (!write_coeffs("stage_matrix", k, matrix, k*k*N) ||
            !write_coeffs("stage_s", k, s, k*N) ||
            !write_coeffs("stage_e", k, e, k*N)) return 1;
    }
    return 0;
}
