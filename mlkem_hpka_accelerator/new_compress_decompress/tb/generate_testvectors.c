#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>

#define Q 3329u
#define N 256

// Exact implementations from roundtripstockham.c
static uint16_t c_compress_coeff(uint16_t x, unsigned d) {
    uint32_t dividend = (uint32_t)x << d;
    uint32_t q0 = (uint32_t)(((uint64_t)dividend * 5039u) >> 24);
    uint32_t rem = dividend - q0 * Q;

    uint32_t q1 = q0 + (((Q/2 - rem) >> 31) & 1u);
    uint32_t q2 = q1 + ((((Q + Q/2) - rem) >> 31) & 1u);

    return (uint16_t)(q2 & ((1u << d) - 1));
}

static uint16_t c_decompress_coeff(uint16_t x, unsigned d) {
    uint32_t t = (uint32_t)Q * x + (1u << (d-1));
    return (uint16_t)(t >> d);
}

static void write_vectors(const char *prefix) {
    char path_c_in[128], path_c_exp[128], path_d_in[128], path_d_exp[128], path_hdr[128];
    snprintf(path_c_in, sizeof(path_c_in), "%s/tv_compress_in.hex", prefix);
    snprintf(path_c_exp, sizeof(path_c_exp), "%s/tv_compress_exp.hex", prefix);
    snprintf(path_d_in, sizeof(path_d_in), "%s/tv_decompress_in.hex", prefix);
    snprintf(path_d_exp, sizeof(path_d_exp), "%s/tv_decompress_exp.hex", prefix);
    snprintf(path_hdr, sizeof(path_hdr), "%s/tv_counts.vh", prefix);

    FILE *f_comp_in  = fopen(path_c_in, "w");
    FILE *f_comp_exp = fopen(path_c_exp, "w");
    FILE *f_dec_in   = fopen(path_d_in, "w");
    FILE *f_dec_exp  = fopen(path_d_exp, "w");

    if (!f_comp_in || !f_comp_exp || !f_dec_in || !f_dec_exp) {
        perror("Error opening testvector files");
        return;
    }

    int d_list[] = {1, 4, 5, 10, 11};
    int num_d = sizeof(d_list) / sizeof(d_list[0]);
    unsigned comp_count = 0;
    unsigned dec_count = 0;

    // 1. Comprehensive Decompress Vectors for all d:
    // Format: single 4-hex-digit token: {d[3:0], y[10:0]}
    for (int di = 0; di < num_d; di++) {
        unsigned d = d_list[di];
        unsigned max_y = 1u << d;
        for (unsigned y = 0; y < max_y; y++) {
            uint16_t exp = c_decompress_coeff((uint16_t)y, d);
            uint32_t word = ((d & 0xF) << 11) | (y & 0x7FF);
            fprintf(f_dec_in, "%04X\n", word);
            fprintf(f_dec_exp, "%03X\n", exp);
            dec_count++;
        }
    }

    // 2. Comprehensive Compress Vectors for all d:
    // Format: single 5-hex-digit token: {d[3:0], x[15:0]} (20 bits)
    for (int di = 0; di < num_d; di++) {
        unsigned d = d_list[di];
        for (uint32_t x = 0; x < Q; ) {
            uint16_t exp = c_compress_coeff((uint16_t)x, d);
            uint32_t word = ((d & 0xF) << 16) | (x & 0xFFFF);
            fprintf(f_comp_in, "%05X\n", word);
            fprintf(f_comp_exp, "%03X\n", exp);
            comp_count++;

            if (x < 64 || (x >= 1640 && x <= 1690) || x >= 3300) {
                x += 1;
            } else {
                x += 7;
            }
        }

        // Lazy reduction negative inputs: centered [-Q, -1]
        int neg_steps[] = {-1, -2, -10, -500, -1664, -1665, -2500, -3328, -3329};
        for (size_t ni = 0; ni < sizeof(neg_steps)/sizeof(neg_steps[0]); ni++) {
            int16_t raw = (int16_t)neg_steps[ni];
            uint16_t reduced = (uint16_t)(raw + Q);
            uint16_t exp = c_compress_coeff(reduced, d);
            uint32_t word = ((d & 0xF) << 16) | ((uint16_t)raw);
            fprintf(f_comp_in, "%05X\n", word);
            fprintf(f_comp_exp, "%03X\n", exp);
            comp_count++;
        }
    }

    // 3. Realistic Polynomial Streams (N = 256 coefficients per poly)
    srand(0x12345678);
    int stream_d[] = {10, 4, 11, 5, 1};
    for (int s = 0; s < 5; s++) {
        unsigned d = stream_d[s];
        for (int i = 0; i < N; i++) {
            uint32_t x = rand() % Q;
            uint16_t exp = c_compress_coeff((uint16_t)x, d);
            uint32_t word = ((d & 0xF) << 16) | (x & 0xFFFF);
            fprintf(f_comp_in, "%05X\n", word);
            fprintf(f_comp_exp, "%03X\n", exp);
            comp_count++;
        }
    }

    fclose(f_comp_in);
    fclose(f_comp_exp);
    fclose(f_dec_in);
    fclose(f_dec_exp);

    // Write counts header
    FILE *f_hdr = fopen(path_hdr, "w");
    if (f_hdr) {
        fprintf(f_hdr, "`define NUM_COMP_TESTS %u\n", comp_count);
        fprintf(f_hdr, "`define NUM_DEC_TESTS %u\n", dec_count);
        fclose(f_hdr);
    }

    printf("Successfully wrote testvectors to %s:\n", prefix);
    printf("  Compress vectors:   %u\n", comp_count);
    printf("  Decompress vectors: %u\n", dec_count);
}

int main() {
    write_vectors("sim");
    write_vectors("tb/sim");
    return 0;
}
