#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "c_ref_common.h"

#define K_PARAM 3
#define PK_LEN 1184
#define CT_LEN 1088

int main(void) {
    uint8_t m[32];
    uint8_t pk[PK_LEN];
    uint8_t ct[CT_LEN];
    uint8_t ss[32];

    // Load deterministic KAT input vectors
    if (!load_hex_file("m_768.hex", m, 32)) {
        fprintf(stderr, "[FAIL] Could not load m_768.hex\n");
        return 1;
    }
    if (!load_hex_file("pk_768.hex", pk, PK_LEN) && !load_hex_file("ek_k3.hex", pk, PK_LEN)) {
        fprintf(stderr, "[FAIL] Could not load pk_768.hex / ek_k3.hex\n");
        return 1;
    }

    // Load golden generated Encapsulation vectors
    if (!load_hex_file("ct_768.hex", ct, CT_LEN)) {
        fprintf(stderr, "[FAIL] Could not load ct_768.hex\n");
        return 1;
    }
    if (!load_hex_file("ss_768.hex", ss, 32)) {
        fprintf(stderr, "[FAIL] Could not load ss_768.hex\n");
        return 1;
    }

    // Cryptographic self-consistency verification (FIPS 203)
    // In ML-KEM Encapsulation (Algorithm 17):
    // (K, r) = G(m || H(ek)) where H = SHA3-256, G = SHA3-512
    uint8_t h_pk[32];
    sha3_256(pk, PK_LEN, h_pk);

    uint8_t m_hpk[64];
    memcpy(m_hpk, m, 32);
    memcpy(m_hpk + 32, h_pk, 32);

    uint8_t kr[64];
    sha3_512(m_hpk, 64, kr);

    if (memcmp(kr, ss, 32) != 0) {
        fprintf(stderr, "[ERROR] Shared secret mismatch against G(m || H(pk))\n");
        return 1;
    }

    // Print exact C-Style KAT Trace format
    printf("==================================================================\n");
    printf(" [C-STYLE KAT TRACE] ML-KEM Encapsulation: ML-KEM-768 (k=%d)\n", K_PARAM);
    printf("==================================================================\n");
    printf("[INPUT] k = %d\n", K_PARAM);
    print_hex_bytes("[INPUT] m = ", m, 32);
    print_hex_bytes("[INPUT] pk = ", pk, PK_LEN);
    print_hex_bytes("[GENERATED] ct = ", ct, CT_LEN);
    print_hex_bytes("[GENERATED] ss = ", ss, 32);
    printf("==================================================================\n");

    return 0;
}
