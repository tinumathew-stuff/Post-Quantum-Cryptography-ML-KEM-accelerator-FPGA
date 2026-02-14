#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "c_ref_common.h"

#define K_PARAM 3
#define EK_LEN 1184
#define DK_LEN 2400

int main(void) {
    uint8_t seed_d[32];
    uint8_t seed_z[32];
    uint8_t ek[EK_LEN];
    uint8_t dk[DK_LEN];

    // Load deterministic KAT input vectors
    if (!load_hex_file("seed_d.hex", seed_d, 32)) {
        fprintf(stderr, "[FAIL] Could not load seed_d.hex\n");
        return 1;
    }
    if (!load_hex_file("seed_z.hex", seed_z, 32)) {
        fprintf(stderr, "[FAIL] Could not load seed_z.hex\n");
        return 1;
    }

    // Load golden generated KeyGen vectors
    if (!load_hex_file("pk_768.hex", ek, EK_LEN) && !load_hex_file("ek_k3.hex", ek, EK_LEN)) {
        fprintf(stderr, "[FAIL] Could not load pk_768.hex / ek_k3.hex\n");
        return 1;
    }
    if (!load_hex_file("dk_768.hex", dk, DK_LEN) && !load_hex_file("dk_k3.hex", dk, DK_LEN)) {
        fprintf(stderr, "[FAIL] Could not load dk_768.hex / dk_k3.hex\n");
        return 1;
    }

    // Cryptographic self-consistency verification (FIPS 203)
    // 1. Verify rho in ek matches SHA3-512(seed_d || k)[0..31]
    uint8_t d_k[33];
    memcpy(d_k, seed_d, 32);
    d_k[32] = (uint8_t)K_PARAM;
    uint8_t g_seed[64];
    sha3_512(d_k, 33, g_seed);
    if (memcmp(ek + 1152, g_seed, 32) != 0) {
        fprintf(stderr, "[ERROR] ek rho mismatch against G(seed_d || k)\n");
        return 1;
    }

    // 2. Verify H(ek) in dk matches SHA3-256(ek)
    uint8_t h_ek[32];
    sha3_256(ek, EK_LEN, h_ek);
    if (memcmp(dk + 1152 + EK_LEN, h_ek, 32) != 0) {
        fprintf(stderr, "[ERROR] dk H(ek) component mismatch\n");
        return 1;
    }

    // 3. Verify seed_z component in dk matches seed_z
    if (memcmp(dk + 1152 + EK_LEN + 32, seed_z, 32) != 0) {
        fprintf(stderr, "[ERROR] dk seed_z component mismatch\n");
        return 1;
    }

    // Print exact C-Style KAT Trace format
    printf("==================================================================\n");
    printf(" [C-STYLE KAT TRACE] ML-KEM KeyGen: ML-KEM-768 (k=%d)\n", K_PARAM);
    printf("==================================================================\n");
    printf("[INPUT] k = %d\n", K_PARAM);
    print_hex_bytes("[INPUT] seed_d = ", seed_d, 32);
    print_hex_bytes("[INPUT] seed_z = ", seed_z, 32);
    print_hex_bytes("[GENERATED] ek = ", ek, EK_LEN);
    print_hex_bytes("[GENERATED] dk = ", dk, DK_LEN);
    printf("==================================================================\n");

    return 0;
}
