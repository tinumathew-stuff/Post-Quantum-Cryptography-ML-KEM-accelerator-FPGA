#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define main reference_main
#include "/home/tinu/Projects/ultimatecode/stockham4butterfly/roundtripstockham.c"
#undef main

static uint32_t rng = 0x481593abu;
static uint32_t random32(void) {
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
}

static int centered(int64_t x) {
    int r = (int)(x % 3329);
    if (r > 1664) r -= 3329;
    if (r < -1664) r += 3329;
    return r;
}

static int16_t sample(unsigned pattern, unsigned i) {
    const int16_t edge[] = {0, 1, -1, 1664, -1664, 1665, -1665, 3328, -3328};
    if (pattern == 0) return 0;
    if (pattern == 1) return 3328;
    if (pattern == 2) return -3328;
    if (pattern == 3) return edge[i % 9];
    return (int16_t)((int)(random32() % 6657) - 3328);
}

static unsigned records = 0, results = 0, jobs = 0;

static void job(FILE *f, unsigned mode, unsigned k, unsigned pattern, unsigned base, unsigned accumulate) {
    int16_t a[4096], b[1024], out[1024];
    unsigned rows = (mode == 3) ? k : 1;
    unsigned terms = (mode >= 2 || accumulate) ? k : 1;
    unsigned beats = (mode == 0) ? 1 : 64;

    for (unsigned i = 0; i < rows * terms * 256; i++) a[i] = sample(pattern, i);
    for (unsigned i = 0; i < terms * 256; i++) b[i] = sample(pattern, i + 3);

    if (pattern == 6) {
        for (unsigned i = 0; i < rows * terms * 256; i++) a[i] = -1;
        for (unsigned i = 0; i < terms * 256; i++) b[i] = (i & 1) ? 0 : 1;
    }
    if (pattern == 7) {
        polyvec_ntt(a, rows * terms);
        polyvec_ntt(b, terms);
    }

    if (mode == 0 && !accumulate) {
        basemul(a + 4 * base, b + 4 * base, out + 4 * base, POLYMUL_ZETA[2 * base]);
        basemul(a + 4 * base + 2, b + 4 * base + 2, out + 4 * base + 2, POLYMUL_ZETA[2 * base + 1]);
    }
    if (mode == 1 && !accumulate) polymul_ntt(a, b, out);
    if (mode < 2 && accumulate)   vec_vec_mul(a, b, out, k);
    if (mode == 2)                vec_vec_mul(a, b, out, k);
    if (mode == 3)                matrix_vec_mul(a, b, out, k);

    for (unsigned row = 0; row < rows; row++) {
        for (unsigned beat = 0; beat < beats; beat++) {
            unsigned idx = (mode == 0) ? base : beat;
            int64_t check0 = 0, check1 = 0, check2 = 0, check3 = 0;
            int z0 = plantard_mul_const(1, POLYMUL_ZETA[2 * idx]);
            int z1 = plantard_mul_const(1, POLYMUL_ZETA[2 * idx + 1]);

            for (unsigned j = 0; j < terms; j++) {
                unsigned ai = (row * terms + j) * 256 + 4 * idx;
                unsigned bi = j * 256 + 4 * idx;

                check0 += (int64_t)a[ai + 0] * b[bi + 0] + (int64_t)a[ai + 1] * b[bi + 1] * z0;
                check1 += (int64_t)a[ai + 0] * b[bi + 1] + (int64_t)a[ai + 1] * b[bi + 0];
                check2 += (int64_t)a[ai + 2] * b[bi + 2] + (int64_t)a[ai + 3] * b[bi + 3] * z1;
                check3 += (int64_t)a[ai + 2] * b[bi + 3] + (int64_t)a[ai + 3] * b[bi + 2];

                int emit = (j + 1 == terms);
                int last = emit && (beat + 1 == beats) && (row + 1 == rows);

                fprintf(f, "%x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x %x\n",
                    (row == 0 && beat == 0 && j == 0),
                    mode, k, idx,
                    (unsigned)a[ai + 0] & 8191, (unsigned)a[ai + 1] & 8191,
                    (unsigned)a[ai + 2] & 8191, (unsigned)a[ai + 3] & 8191,
                    (unsigned)b[bi + 0] & 8191, (unsigned)b[bi + 1] & 8191,
                    (unsigned)b[bi + 2] & 8191, (unsigned)b[bi + 3] & 8191,
                    emit,
                    (unsigned)out[row * 256 + 4 * idx + 0] & 4095,
                    (unsigned)out[row * 256 + 4 * idx + 1] & 4095,
                    (unsigned)out[row * 256 + 4 * idx + 2] & 4095,
                    (unsigned)out[row * 256 + 4 * idx + 3] & 4095,
                    idx, row, last, accumulate);

                records++;
                results += emit;
            }

            assert(centered(check0) == out[row * 256 + 4 * idx + 0]);
            assert(centered(check1) == out[row * 256 + 4 * idx + 1]);
            assert(centered(check2) == out[row * 256 + 4 * idx + 2]);
            assert(centered(check3) == out[row * 256 + 4 * idx + 3]);
        }
    }
    jobs++;
}

static void corners(FILE *f) {
    const int16_t edge[] = {0, 1, -1, 1664, -1664, 1665, -1665, 3328, -3328};
    for (unsigned n = 0; n < 2187; n++) {
        unsigned v = n, idx = n % 64;
        int16_t a[4], b[4], h[4];
        a[0] = edge[v % 9]; v /= 9;
        a[1] = edge[v % 9]; v /= 9;
        b[0] = edge[v % 9]; v /= 9;
        b[1] = edge[v % 9];
        a[2] = a[1]; a[3] = a[0];
        b[2] = b[1]; b[3] = b[0];

        basemul(a, b, h, POLYMUL_ZETA[2 * idx]);
        basemul(a + 2, b + 2, h + 2, POLYMUL_ZETA[2 * idx + 1]);

        fprintf(f, "1 0 2 %x %x %x %x %x %x %x %x %x 1 %x %x %x %x %x 0 1 0\n",
            idx,
            (unsigned)a[0] & 8191, (unsigned)a[1] & 8191,
            (unsigned)a[2] & 8191, (unsigned)a[3] & 8191,
            (unsigned)b[0] & 8191, (unsigned)b[1] & 8191,
            (unsigned)b[2] & 8191, (unsigned)b[3] & 8191,
            (unsigned)h[0] & 4095, (unsigned)h[1] & 4095,
            (unsigned)h[2] & 4095, (unsigned)h[3] & 4095,
            idx);
        records++; results++; jobs++;
    }
}

int main(int argc, char **argv) {
    const char *outfile = (argc > 1) ? argv[1] : "mul_vectors_4way.txt";
    FILE *f = fopen(outfile, "w");
    if (!f) {
        fprintf(stderr, "Failed to open output file: %s\n", outfile);
        return 1;
    }

    printf("Generating 4-way Dual-PWM KAT vectors using Stockham reference...\n");

    // Pattern sweeps across all modes and k values
    for (unsigned pattern = 0; pattern < 8; pattern++) {
        for (unsigned i = 0; i < 64; i++) {
            job(f, 0, 2 + (i % 3), pattern, i, 0);
        }
        job(f, 1, 2 + (pattern % 3), pattern, 0, 0);
        for (unsigned k = 2; k <= 4; k++) {
            job(f, 2, k, pattern, 0, 0);
            job(f, 3, k, pattern, 0, 0);
        }
    }

    corners(f);

    for (unsigned k = 2; k <= 4; k++) {
        for (unsigned pattern = 0; pattern < 8; pattern++) {
            job(f, 0, k, pattern, (17 * pattern) % 64, 1);
            job(f, 1, k, pattern, 0, 1);
        }
    }

    fclose(f);
    printf("Successfully generated %u beats (%u output results, %u jobs) into %s.\n",
           records, results, jobs, outfile);
    return 0;
}
