#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define main stockham_main
#include "../../../stockham4butterfly/roundtripstockham.c"
#undef main

static void print_state_hex(FILE *f, const uint64_t s[25]) {
    // In Verilog [1599:0]: lane 24 is [1599:1536] (MSB), lane 0 is [63:0] (LSB)
    for (int i = 24; i >= 0; i--) {
        fprintf(f, "%016llx", (unsigned long long)s[i]);
    }
    fprintf(f, "\n");
}

int main(void) {
    FILE *fin  = fopen("keccak_f1600_in.hex", "w");
    FILE *fout = fopen("keccak_f1600_out.hex", "w");
    if (!fin || !fout) {
        fprintf(stderr, "Failed to open output files\n");
        return 1;
    }

    uint64_t s[25];

    // Case 0: All zeros
    memset(s, 0, sizeof(s));
    print_state_hex(fin, s);
    keccak_f1600(s);
    print_state_hex(fout, s);

    // Case 1: Single lane non-zero
    memset(s, 0, sizeof(s));
    s[0] = 0x0123456789abcdefULL;
    print_state_hex(fin, s);
    keccak_f1600(s);
    print_state_hex(fout, s);

    // Case 2: Linear pattern across all 25 lanes
    for (int i = 0; i < 25; i++) {
        s[i] = (uint64_t)i * 0x0102030405060708ULL + 0xdeadbeefcafebabeULL;
    }
    print_state_hex(fin, s);
    keccak_f1600(s);
    print_state_hex(fout, s);

    // Case 3..12: 10 iterative chaining rounds (each permutation fed into next)
    for (int iter = 0; iter < 10; iter++) {
        print_state_hex(fin, s);
        keccak_f1600(s);
        print_state_hex(fout, s);
    }

    fclose(fin);
    fclose(fout);
    printf("Successfully generated 13 Keccak-f[1600] KAT vectors using roundtripstockham.c\n");
    return 0;
}
