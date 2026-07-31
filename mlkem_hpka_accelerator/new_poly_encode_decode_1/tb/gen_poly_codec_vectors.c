#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define N 256
#define Q 3329

// Reference implementations matching stockham4butterfly/roundtripstockham.c
static void ref_poly_encode(const int16_t poly[N], uint8_t *out, unsigned l) {
    uint16_t t[N];
    for (unsigned i = 0; i < N; i++) {
        int16_t x = poly[i];
        x += (x >> 15) & Q;
        t[i] = (uint16_t)x;
    }

    memset(out, 0, 32 * l);

    if (l == 1) {
        for (unsigned i = 0; i < N/8; i++) {
            uint8_t byte = 0;
            for (unsigned j = 0; j < 8; j++)
                byte |= (t[i*8+j] & 1u) << j;
            out[i] = byte;
        }
    } else if (l == 4) {
        for (unsigned i = 0; i < N/2; i++)
            out[i] = (uint8_t)((t[2*i] & 0xF) | ((t[2*i+1] & 0xF) << 4));
    } else if (l == 5) {
        for (unsigned i = 0; i < N/8; i++) {
            const uint16_t *p = t + 8*i;
            uint8_t *b = out + 5*i;
            b[0] = (uint8_t)( p[0]        | ((p[1] & 0x7) << 5));
            b[1] = (uint8_t)((p[1] >> 3)  | ((p[2] & 0x1F) << 2) | ((p[3] & 0x1) << 7));
            b[2] = (uint8_t)((p[3] >> 1)  & 0xF) | (uint8_t)((p[4] & 0xF) << 4);
            b[3] = (uint8_t)((p[4] >> 4)  & 0x1) | (uint8_t)((p[5] & 0x1F) << 1) | (uint8_t)((p[6] & 0x3) << 6);
            b[4] = (uint8_t)((p[6] >> 2)  & 0x7) | (uint8_t)((p[7] & 0x1F) << 3);
        }
    } else if (l == 10) {
        for (unsigned i = 0; i < N/4; i++) {
            const uint16_t *p = t + 4*i;
            uint8_t *b = out + 5*i;
            b[0] = (uint8_t)(p[0]);
            b[1] = (uint8_t)((p[0] >> 8) | ((p[1] & 0x3F) << 2));
            b[2] = (uint8_t)((p[1] >> 6) | ((p[2] & 0xF)  << 4));
            b[3] = (uint8_t)((p[2] >> 4) | ((p[3] & 0x3)  << 6));
            b[4] = (uint8_t)( p[3] >> 2);
        }
    } else if (l == 11) {
        for (unsigned i = 0; i < N/8; i++) {
            const uint16_t *p = t + 8*i;
            uint8_t *b = out + 11*i;
            b[ 0] = (uint8_t)(p[0]);
            b[ 1] = (uint8_t)((p[0] >> 8) | ((p[1] & 0x1F) << 3));
            b[ 2] = (uint8_t)((p[1] >> 5) | ((p[2] & 0x3)  << 6));
            b[ 3] = (uint8_t)((p[2] >> 2) & 0xFF);
            b[ 4] = (uint8_t)((p[2] >> 10) | ((p[3] & 0x7F) << 1));
            b[ 5] = (uint8_t)((p[3] >> 7)  | ((p[4] & 0xF)  << 4));
            b[ 6] = (uint8_t)((p[4] >> 4)  | ((p[5] & 0x1)  << 7));
            b[ 7] = (uint8_t)((p[5] >> 1) & 0xFF);
            b[ 8] = (uint8_t)((p[5] >> 9)  | ((p[6] & 0x3F) << 2));
            b[ 9] = (uint8_t)((p[6] >> 6)  | ((p[7] & 0x7)  << 5));
            b[10] = (uint8_t)( p[7] >> 3);
        }
    } else { /* l == 12 */
        for (unsigned i = 0; i < N/2; i++) {
            out[3*i]     = (uint8_t)(t[2*i]);
            out[3*i + 1] = (uint8_t)((t[2*i] >> 8) | ((t[2*i+1] & 0xF) << 4));
            out[3*i + 2] = (uint8_t)(t[2*i+1] >> 4);
        }
    }
}

static void ref_poly_decode(const uint8_t *in, int16_t poly[N], unsigned l) {
    uint16_t t[N];
    memset(t, 0, sizeof(t));

    if (l == 1) {
        for (unsigned i = 0; i < N/8; i++)
            for (unsigned j = 0; j < 8; j++)
                t[8*i+j] = (in[i] >> j) & 1u;
    } else if (l == 4) {
        for (unsigned i = 0; i < N/2; i++) {
            t[2*i]   = in[i] & 0xF;
            t[2*i+1] = in[i] >> 4;
        }
    } else if (l == 5) {
        for (unsigned i = 0; i < N/8; i++) {
            const uint8_t *b = in + 5*i;
            uint16_t *p = t + 8*i;
            p[0] =  b[0]         & 0x1F;
            p[1] = (b[0] >> 5)   | ((b[1] & 0x3)  << 3);
            p[2] = (b[1] >> 2)   & 0x1F;
            p[3] = (b[1] >> 7)   | ((b[2] & 0xF)  << 1);
            p[4] = (b[2] >> 4)   | ((b[3] & 0x1)  << 4);
            p[5] = (b[3] >> 1)   & 0x1F;
            p[6] = (b[3] >> 6)   | ((b[4] & 0x7)  << 2);
            p[7] =  b[4] >> 3;
        }
    } else if (l == 10) {
        for (unsigned i = 0; i < N/4; i++) {
            const uint8_t *b = in + 5*i;
            uint16_t *p = t + 4*i;
            p[0] =  b[0]          | ((uint16_t)(b[1] & 0x3)  << 8);
            p[1] = (b[1] >> 2)    | ((uint16_t)(b[2] & 0xF)  << 6);
            p[2] = (b[2] >> 4)    | ((uint16_t)(b[3] & 0x3F) << 4);
            p[3] = (b[3] >> 6)    | ((uint16_t) b[4]         << 2);
        }
    } else if (l == 11) {
        for (unsigned i = 0; i < N/8; i++) {
            const uint8_t *b = in + 11*i;
            uint16_t *p = t + 8*i;
            p[0] =  b[0]          | ((uint16_t)(b[1] & 0x7)  << 8);
            p[1] = (b[1] >> 3)    | ((uint16_t)(b[2] & 0x3F) << 5);
            p[2] = (b[2] >> 6)    | ((uint16_t) b[3]         << 2) | ((uint16_t)(b[4] & 0x1) << 10);
            p[3] = (b[4] >> 1)    | ((uint16_t)(b[5] & 0xF)  << 7);
            p[4] = (b[5] >> 4)    | ((uint16_t)(b[6] & 0x7F) << 4);
            p[5] = (b[6] >> 7)    | ((uint16_t) b[7]         << 1) | ((uint16_t)(b[8] & 0x3) << 9);
            p[6] = (b[8] >> 2)    | ((uint16_t)(b[9] & 0x1F) << 6);
            p[7] = (b[9] >> 5)    | ((uint16_t) b[10]        << 3);
        }
    } else { /* l == 12 */
        for (unsigned i = 0; i < N/2; i++) {
            t[2*i]   = (uint16_t)(in[3*i]) | ((uint16_t)(in[3*i+1] & 0xF) << 8);
            t[2*i+1] = (uint16_t)(in[3*i+1] >> 4) | ((uint16_t)in[3*i+2] << 4);
        }
    }

    for (unsigned i = 0; i < N; i++) {
        poly[i] = (int16_t)t[i];
    }
}

// PRNG
static uint64_t rng = 0x123456789abcdef0ULL;
static uint32_t xorshift32(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)rng;
}

static const unsigned supported_d[] = {1, 4, 5, 10, 11, 12};
#define NUM_D 6

int main(void) {
    FILE *f_enc_cmd = fopen("sim/encode_commands.hex", "w");
    FILE *f_enc_in  = fopen("sim/encode_in.hex", "w");
    FILE *f_enc_exp = fopen("sim/encode_expected.hex", "w");

    FILE *f_dec_cmd = fopen("sim/decode_commands.hex", "w");
    FILE *f_dec_in  = fopen("sim/decode_in.hex", "w");
    FILE *f_dec_exp = fopen("sim/decode_expected.hex", "w");

    if (!f_enc_cmd || !f_enc_in || !f_enc_exp || !f_dec_cmd || !f_dec_in || !f_dec_exp) {
        fprintf(stderr, "Error opening output vector files in sim/\n");
        return 1;
    }

    uint32_t enc_offset_in = 0, enc_offset_out = 0;
    uint32_t dec_offset_in = 0, dec_offset_out = 0;
    uint32_t enc_num_cmds = 0, dec_num_cmds = 0;

    int16_t poly_in[N];
    uint8_t bytes_out[32 * 12];
    uint8_t bytes_in[32 * 12];
    int16_t poly_exp[N];

    // Generate comprehensive testcases across all d and pressure modes
    for (int di = 0; di < NUM_D; di++) {
        unsigned d = supported_d[di];
        uint32_t max_val = (1u << d) - 1;
        unsigned num_bytes = 32 * d;

        // Test patterns:
        // 0: All zeros
        // 1: All ones (max_val)
        // 2: Alternating (0, max_val, 0, max_val...)
        // 3: Linear ramp (i % (max_val + 1))
        // 4: Walking 1s (1 << (i % d))
        // 5: Impulse at 0
        // 6: Impulse at 1
        // 7: Impulse at 7
        // 8: Impulse at 8
        // 9: Impulse at 255
        // 10: Random pattern 1
        // 11: Random pattern 2
        // 12: Random pattern 3
        // 13: Random pattern 4
        // 14: Boundary values for d=12 (Q-1, Q, 4095)
        int num_patterns = (d == 12) ? 15 : 14;

        for (int pat = 0; pat < num_patterns; pat++) {
            memset(poly_in, 0, sizeof(poly_in));

            if (pat == 0) {
                // All zeros
                for (int i = 0; i < N; i++) poly_in[i] = 0;
            } else if (pat == 1) {
                // All max
                for (int i = 0; i < N; i++) poly_in[i] = (int16_t)max_val;
            } else if (pat == 2) {
                // Alternating
                for (int i = 0; i < N; i++) poly_in[i] = (i & 1) ? (int16_t)max_val : 0;
            } else if (pat == 3) {
                // Linear ramp
                for (int i = 0; i < N; i++) poly_in[i] = (int16_t)(i % (max_val + 1));
            } else if (pat == 4) {
                // Walking 1s
                for (int i = 0; i < N; i++) poly_in[i] = (int16_t)(1u << (i % d));
            } else if (pat == 5) {
                // Impulse at 0
                poly_in[0] = (int16_t)max_val;
            } else if (pat == 6) {
                // Impulse at 1
                poly_in[1] = (int16_t)max_val;
            } else if (pat == 7) {
                // Impulse at 7
                poly_in[7] = (int16_t)max_val;
            } else if (pat == 8) {
                // Impulse at 8
                poly_in[8] = (int16_t)max_val;
            } else if (pat == 9) {
                // Impulse at 255
                poly_in[255] = (int16_t)max_val;
            } else if (pat >= 10 && pat <= 13) {
                // Random
                for (int i = 0; i < N; i++) poly_in[i] = (int16_t)(xorshift32() & max_val);
            } else if (pat == 14 && d == 12) {
                // Boundary values for Kyber/ML-KEM: 0, 1, Q-1 (3328), Q (3329), 4095
                for (int i = 0; i < N; i++) {
                    int sel = i % 5;
                    if (sel == 0) poly_in[i] = 0;
                    else if (sel == 1) poly_in[i] = 1;
                    else if (sel == 2) poly_in[i] = Q - 1;
                    else if (sel == 3) poly_in[i] = Q;
                    else poly_in[i] = 4095;
                }
            }

            // Reference encode
            ref_poly_encode(poly_in, bytes_out, d);

            // Assign a backpressure mode (0 to 10)
            unsigned bp_mode = (enc_num_cmds % 11);

            // Command format:
            // bits [107:104]: d (4b)
            // bits [103:100]: bp_mode (4b)
            // bits [99:84]: words_in (16b) = 256
            // bits [83:68]: words_out (16b) = num_bytes
            // bits [67:36]: offset_in (32b)
            // bits [35:4]: offset_out (32b)
            // bits [3:0]: 0 (pad)
            // Total 108 bits = 27 hex digits
            fprintf(f_enc_cmd, "%01x_%01x_%04x_%04x_%08x_%08x\n",
                    d, bp_mode, 256, num_bytes, enc_offset_in, enc_offset_out);

            // Write input coeffs
            for (int i = 0; i < N; i++) {
                uint16_t c = (uint16_t)poly_in[i] & 0xFFF;
                fprintf(f_enc_in, "%03x\n", c);
            }
            enc_offset_in += 256;

            // Write expected bytes
            for (unsigned i = 0; i < num_bytes; i++) {
                fprintf(f_enc_exp, "%02x\n", bytes_out[i]);
            }
            enc_offset_out += num_bytes;
            enc_num_cmds++;

            // =========================================================
            // Now generate decode vector using bytes_out as input!
            // This tests exact decode of valid encoded data!
            // =========================================================
            ref_poly_decode(bytes_out, poly_exp, d);

            unsigned dec_bp = (dec_num_cmds % 11);
            fprintf(f_dec_cmd, "%01x_%01x_%04x_%04x_%08x_%08x\n",
                    d, dec_bp, num_bytes, 256, dec_offset_in, dec_offset_out);

            // Write input bytes
            for (unsigned i = 0; i < num_bytes; i++) {
                fprintf(f_dec_in, "%02x\n", bytes_out[i]);
            }
            dec_offset_in += num_bytes;

            // Write expected output coefficients
            for (int i = 0; i < N; i++) {
                uint16_t c = (uint16_t)poly_exp[i] & 0xFFF;
                fprintf(f_dec_exp, "%03x\n", c);
            }
            dec_offset_out += 256;
            dec_num_cmds++;
        }

        // Additional decode test with arbitrary pseudo-random input bytes
        for (int r = 0; r < 3; r++) {
            for (unsigned i = 0; i < num_bytes; i++) {
                bytes_in[i] = (uint8_t)(xorshift32() & 0xFF);
            }
            ref_poly_decode(bytes_in, poly_exp, d);

            unsigned dec_bp = (dec_num_cmds % 11);
            fprintf(f_dec_cmd, "%01x_%01x_%04x_%04x_%08x_%08x\n",
                    d, dec_bp, num_bytes, 256, dec_offset_in, dec_offset_out);

            for (unsigned i = 0; i < num_bytes; i++) {
                fprintf(f_dec_in, "%02x\n", bytes_in[i]);
            }
            dec_offset_in += num_bytes;

            for (int i = 0; i < N; i++) {
                uint16_t c = (uint16_t)poly_exp[i] & 0xFFF;
                fprintf(f_dec_exp, "%03x\n", c);
            }
            dec_offset_out += 256;
            dec_num_cmds++;
        }
    }

    fclose(f_enc_cmd);
    fclose(f_enc_in);
    fclose(f_enc_exp);
    fclose(f_dec_cmd);
    fclose(f_dec_in);
    fclose(f_dec_exp);

    printf("Successfully generated test vectors:\n");
    printf("  Encode: %u commands, %u coeffs in, %u bytes out\n",
           enc_num_cmds, enc_offset_in, enc_offset_out);
    printf("  Decode: %u commands, %u bytes in, %u coeffs out\n",
           dec_num_cmds, dec_offset_in, dec_offset_out);

    // Also write a metadata header for SystemVerilog
    FILE *f_meta = fopen("sim/vector_meta.vh", "w");
    if (f_meta) {
        fprintf(f_meta, "`define ENC_NUM_CMDS %u\n", enc_num_cmds);
        fprintf(f_meta, "`define ENC_TOTAL_WORDS_IN %u\n", enc_offset_in);
        fprintf(f_meta, "`define ENC_TOTAL_WORDS_OUT %u\n", enc_offset_out);
        fprintf(f_meta, "`define DEC_NUM_CMDS %u\n", dec_num_cmds);
        fprintf(f_meta, "`define DEC_TOTAL_WORDS_IN %u\n", dec_offset_in);
        fprintf(f_meta, "`define DEC_TOTAL_WORDS_OUT %u\n", dec_offset_out);
        fclose(f_meta);
    }

    return 0;
}
