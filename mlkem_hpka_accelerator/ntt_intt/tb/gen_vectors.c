#include <stdlib.h>
#define main original_reference_main
#include "../../stockham4butterfly/roundtripstockham.c"
#undef main

static uint32_t random_state = 0x7348b12d;
static uint32_t random32(void) {
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}
static unsigned canonical(int16_t a) {
    int v = a % 3329;
    return (unsigned)(v < 0 ? v + 3329 : v);
}
int main(void) {
    FILE *in = fopen("vectors_input.hex", "w");
    FILE *fwd = fopen("vectors_ntt.hex", "w");
    FILE *inv = fopen("vectors_intt.hex", "w");
    FILE *rom = fopen("../rtl/mlkem_twiddle.svh", "w");
    FILE *trace = fopen("trace_ntt.hex", "w");
    FILE *trace_inv = fopen("trace_intt.hex", "w");
    if (!in || !fwd || !inv || !rom || !trace || !trace_inv) return 1;
    fprintf(rom, "// Generated from the supplied C constants; regenerate with make vectors.\n");
    fprintf(rom, "function automatic logic signed [31:0] twiddle(input logic inverse, input logic [6:0] index);\n    logic [31:0] part0,part1,part2,part3;\n");
    for (unsigned half=0;half<4;half++)
        for (unsigned bit=0;bit<32;bit++) {
            uint64_t truth=0;
            for(unsigned i=0;i<64;i++) {
                uint32_t w=half>=2 ? INTT_ZETA[(half-2)*64+i] : NTT_ZETA[half*64+i];
                truth|=(uint64_t)((w>>bit)&1)<<i;
            }
            fprintf(rom,"    part%u[%u] = (64'h%016llx >> index[5:0]) & 1'b1;\n",half,bit,(unsigned long long)truth);
        }
    fprintf(rom,"    case({inverse,index[6]})\n        0:twiddle=part0;\n        1:twiddle=part1;\n        2:twiddle=part2;\n        3:twiddle=part3;\n    endcase\nendfunction\n");
    for (unsigned test = 0; test < 80; ++test) {
        int16_t x[256], a[256], b[256];
        for (unsigned i = 0; i < 256; ++i) {
            unsigned v;
            switch (test) {
                case 0: v = 0; break;
                case 1: v = 3328; break;
                case 2: v = 1; break;
                case 3: v = i & 1 ? 3328 : 0; break;
                case 4: v = i; break;
                case 5: v = i == 0; break;
                case 6: v = i == 255 ? 3328 : 0; break;
                case 7: v = i & 1 ? 1665 : 1664; break;
                case 8: v = i % 7 == 0 ? 3328 : 1; break;
                case 9: v = i < 128 ? 0 : 3328; break;
                case 10: v = i == 127 ? 1 : 0; break;
                case 11: v = i == 128 ? 1 : 0; break;
                default: v = random32() % 3329; break;
            }
            x[i] = a[i] = b[i] = (int16_t)v;
            fprintf(in, "%03x\n", v);
        }
        if (test == 4) {
            int16_t d[256]; memcpy(d,x,sizeof d);
            for (unsigned half=128;half>=2;half>>=1) {
                for (unsigned group=0;group<128/half;group++)
                    for (unsigned j=0;j<half;j++) {
                        unsigned ai=group*half*2+j, bi=ai+half;
                        int16_t t=plantard_mul_const(d[bi],NTT_ZETA[128/half+group]);
                        int16_t av=d[ai];
                        d[ai]=barrett_reduce_32_signed(av+t);
                        d[bi]=barrett_reduce_32_signed(av-t);
                    }
                for(unsigned i=0;i<256;i++) fprintf(trace,"%03x\n",canonical(d[i]));
            }
        }
        ntt_forward(a);
        ntt_inverse(b);
        if(test==4) {
            int16_t d[256]; memcpy(d,x,sizeof d);
            for(unsigned half=2;half<=128;half<<=1) {
                for(unsigned group=0;group<128/half;group++)
                    for(unsigned j=0;j<half;j++) {
                        unsigned ai=group*half*2+j,bi=ai+half;
                        int16_t av=d[ai],bv=d[bi];
                        d[ai]=barrett_reduce_32_signed(av+bv);
                        d[bi]=plantard_mul_const(av-bv,INTT_ZETA[256/half-1-group]);
                    }
                for(unsigned i=0;i<256;i++) fprintf(trace_inv,"%03x\n",canonical(d[i]));
            }
            for(unsigned i=0;i<256;i++) fprintf(trace_inv,"%03x\n",canonical(plantard_mul_const(d[i],INV_N_OVER_2)));
        }
        for (unsigned i = 0; i < 256; ++i) {
            fprintf(fwd, "%03x\n", canonical(a[i]));
            fprintf(inv, "%03x\n", canonical(b[i]));
        }
        ntt_inverse(a);
        for (unsigned i = 0; i < 256; ++i)
            if (canonical(a[i]) != canonical(x[i])) {
                fprintf(stderr, "C roundtrip failed test=%u coeff=%u\n", test, i);
                return 2;
            }
    }
    fclose(in); fclose(fwd); fclose(inv); fclose(rom); fclose(trace); fclose(trace_inv);
    puts("Generated 80 input/NTT/INTT polynomials and 256 C twiddle constants; C roundtrips pass.");
    return 0;
}
