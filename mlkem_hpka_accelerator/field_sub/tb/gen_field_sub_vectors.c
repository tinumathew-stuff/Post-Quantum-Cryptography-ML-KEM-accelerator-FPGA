#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#define Q 3329

static inline int16_t field_sub(int16_t a, int16_t b) {
    int16_t r = a - b;
    r += (r >> 15) & Q;
    return r;
}

int main(void) {
    FILE *fa = fopen("field_sub/tb/input_a.hex", "w");
    FILE *fb = fopen("field_sub/tb/input_b.hex", "w");
    FILE *fe = fopen("field_sub/tb/expected.hex", "w");

    if (!fa || !fb || !fe) {
        fprintf(stderr, "Error opening vector files for writing.\n");
        return 1;
    }

    int count = 0;

    void add_vector(int16_t a, int16_t b) {
        int16_t exp = field_sub(a, b);
        fprintf(fa, "%03x\n", (uint16_t)a & 0xFFF);
        fprintf(fb, "%03x\n", (uint16_t)b & 0xFFF);
        fprintf(fe, "%03x\n", (uint16_t)exp & 0xFFF);
        count++;
    }

    // 1. Fundamental zeros, ones, equals
    add_vector(0, 0);
    add_vector(0, 1);           // 0 - 1 -> Q - 1 = 3328
    add_vector(1, 0);           // 1
    add_vector(1, 1);           // 0

    // 2. Extremes and underflow wrap boundaries
    add_vector(0, Q - 1);       // 0 - 3328 -> 1
    add_vector(Q - 1, 0);       // 3328
    add_vector(Q - 1, Q - 1);   // 0
    add_vector(Q - 1, 1);       // 3327
    add_vector(1, Q - 1);       // 1 - 3328 -> 2
    add_vector(2, Q - 1);       // 2 - 3328 -> 3
    add_vector(0, Q - 2);       // 2
    add_vector(Q - 2, 0);       // 3327
    add_vector(Q - 2, Q - 1);   // 3328
    add_vector(Q - 1, Q - 2);   // 1

    // 3. Boundary delta sweeps around equal values
    for (int delta = -10; delta <= 10; delta++) {
        int16_t a = 1664;
        int16_t b = (a + delta + Q) % Q;
        add_vector(a, b);
    }

    // 4. Powers of two combinations
    int16_t p2[] = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048};
    int num_p2 = sizeof(p2)/sizeof(p2[0]);
    for (int i = 0; i < num_p2; i++) {
        for (int j = 0; j < num_p2; j++) {
            add_vector(p2[i], p2[j]);
            add_vector(p2[j], p2[i]);
        }
    }

    // 5. Linear sweeps
    for (int16_t i = 0; i < 200; i++) {
        add_vector(i, i);
        add_vector(i, 0);
        add_vector(0, i);
        add_vector(i, Q - 1);
        add_vector(Q - 1, i);
        add_vector(i, (i + 1) % Q);
        add_vector((i + 1) % Q, i);
    }

    // 6. High-end boundary sweep
    for (int16_t i = Q - 100; i < Q; i++) {
        for (int16_t j = Q - 10; j < Q; j++) {
            add_vector(i, j);
            add_vector(j, i);
        }
    }

    // 7. Pseudo-random vectors (5,000 cases with fixed seed for reproducibility)
    srand(54321);
    for (int i = 0; i < 5000; i++) {
        int16_t a = rand() % Q;
        int16_t b = rand() % Q;
        add_vector(a, b);
    }

    fclose(fa);
    fclose(fb);
    fclose(fe);

    printf("Generated %d field_sub test vectors successfully.\n", count);
    return 0;
}
