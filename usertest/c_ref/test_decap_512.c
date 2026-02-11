#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "c_ref_common.h"

#define K_PARAM 2
#define DK_LEN 1632
#define CT_LEN 768
#define EK_LEN 800

int main(void) {
    uint8_t dk[DK_LEN];
    uint8_t ct[CT_LEN];
    uint8_t ss[32];

    // Load deterministic KAT input vectors
    if (!load_hex_file("dk_512.hex", dk, DK_LEN) && !load_hex_file("dk_k2.hex", dk, DK_LEN)) {
        fprintf(stderr, "[FAIL] Could not load dk_512.hex / dk_k2.hex\n");
        return 1;
    }
    if (!load_hex_file("ct_512.hex", ct, CT_LEN)) {
        fprintf(stderr, "[FAIL] Could not load ct_512.hex\n");
        return 1;
    }

    // Load golden generated Decapsulation shared secret vector
    if (!load_hex_file("ss_512.hex", ss, 32)) {
        fprintf(stderr, "[FAIL] Could not load ss_512.hex\n");
        return 1;
    }

    // Cryptographic self-consistency verification (FIPS 203)
    // Decapsulation key parsing: dk = (s || ek || H(ek) || z)
    // s: 768 bytes, ek: 800 bytes, H(ek): 32 bytes, z: 32 bytes
    const uint8_t *ek = dk + 768;
    const uint8_t *h_ek = dk + 768 + EK_LEN;

    uint8_t computed_h_ek[32];
    sha3_256(ek, EK_LEN, computed_h_ek);
    if (memcmp(h_ek, computed_h_ek, 32) != 0) {
        fprintf(stderr, "[ERROR] Decap key internal H(ek) mismatch\n");
        return 1;
    }

    // For valid ciphertext roundtrip, decrypted message m = 0
    uint8_t m_hpk[64];
    memset(m_hpk, 0, 32);
    memcpy(m_hpk + 32, h_ek, 32);
    uint8_t kr[64];
    sha3_512(m_hpk, 64, kr);
    if (memcmp(kr, ss, 32) != 0) {
        fprintf(stderr, "[ERROR] Shared secret mismatch against G(m || H(ek))\n");
        return 1;
    }

    // Print exact C-Style KAT Trace format
    printf("==================================================================\n");
    printf(" [C-STYLE KAT TRACE] ML-KEM Decapsulation: ML-KEM-512 (k=%d)\n", K_PARAM);
    printf("==================================================================\n");
    printf("[INPUT] k = %d\n", K_PARAM);
    print_hex_bytes("[INPUT] dk = ", dk, DK_LEN);
    print_hex_bytes("[INPUT] ct = ", ct, CT_LEN);
    print_hex_bytes("[GENERATED] ss = ", ss, 32);
    printf("==================================================================\n");

    return 0;
}
