#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main reference_main
#include "roundtripstockham.c"
#undef main

static int write_hex_bytes(const char *path, const uint8_t *bytes, size_t len) {
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "Error: cannot open file %s for writing\n", path);
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        fprintf(f, "%02x\n", bytes[i]);
    }
    fclose(f);
    return 1;
}

static int write_hex_stream(const char *path, const uint8_t *bytes, size_t len) {
    FILE *f = fopen(path, "w");
    if (!f) {
        fprintf(stderr, "Error: cannot open file %s for writing\n", path);
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        fprintf(f, "%02X", bytes[i]);
    }
    fprintf(f, "\n");
    fclose(f);
    return 1;
}

int main(void) {
    printf("==================================================================\n");
    printf(" Generating ML-KEM KeyGen Known Answer Tests (Stockham Reference)\n");
    printf("==================================================================\n");

    // Standard deterministic test seeds
    uint8_t seed_d[32];
    uint8_t seed_z[32];

    for (int i = 0; i < 32; i++) {
        seed_d[i] = (uint8_t)i;
        seed_z[i] = (uint8_t)(31 - i);
    }

    write_hex_bytes("seed_d.hex", seed_d, 32);
    write_hex_bytes("seed_z.hex", seed_z, 32);

    // 1. ML-KEM-512 (k=2)
    {
        uint8_t ek_512[800];
        uint8_t dk_512[1632];
        memset(ek_512, 0, sizeof(ek_512));
        memset(dk_512, 0, sizeof(dk_512));

        printf("[*] Generating ML-KEM-512 (k=2) KeyGen KAT...\n");
        mlkem512_keygen(seed_d, seed_z, ek_512, dk_512);

        write_hex_bytes("ek_k2.hex", ek_512, 800);
        write_hex_bytes("dk_k2.hex", dk_512, 1632);
        write_hex_stream("ek_k2_stream.hex", ek_512, 800);
        write_hex_stream("dk_k2_stream.hex", dk_512, 1632);
        printf("    -> ek_k2: 800 bytes, dk_k2: 1632 bytes generated.\n");
    }

    // 2. ML-KEM-768 (k=3)
    {
        uint8_t ek_768[1184];
        uint8_t dk_768[2400];
        memset(ek_768, 0, sizeof(ek_768));
        memset(dk_768, 0, sizeof(dk_768));

        printf("[*] Generating ML-KEM-768 (k=3) KeyGen KAT...\n");
        mlkem768_keygen(seed_d, seed_z, ek_768, dk_768);

        write_hex_bytes("ek_k3.hex", ek_768, 1184);
        write_hex_bytes("dk_k3.hex", dk_768, 2400);
        write_hex_stream("ek_k3_stream.hex", ek_768, 1184);
        write_hex_stream("dk_k3_stream.hex", dk_768, 2400);
        printf("    -> ek_k3: 1184 bytes, dk_k3: 2400 bytes generated.\n");
    }

    // 3. ML-KEM-1024 (k=4)
    {
        uint8_t ek_1024[1568];
        uint8_t dk_1024[3168];
        memset(ek_1024, 0, sizeof(ek_1024));
        memset(dk_1024, 0, sizeof(dk_1024));

        printf("[*] Generating ML-KEM-1024 (k=4) KeyGen KAT...\n");
        mlkem1024_keygen(seed_d, seed_z, ek_1024, dk_1024);

        write_hex_bytes("ek_k4.hex", ek_1024, 1568);
        write_hex_bytes("dk_k4.hex", dk_1024, 3168);
        write_hex_stream("ek_k4_stream.hex", ek_1024, 1568);
        write_hex_stream("dk_k4_stream.hex", dk_1024, 3168);
        printf("    -> ek_k4: 1568 bytes, dk_k4: 3168 bytes generated.\n");
    }

    printf("==================================================================\n");
    printf(" Stockham KAT generation complete!\n");
    printf("==================================================================\n");
    return 0;
}
