#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
// Reference arithmetic is unchanged; suppress its verbose diagnostic trace.
static int quiet_printf(const char *format, ...) { (void)format; return 0; }
#define printf quiet_printf
#define main stockham_reference_main
#include "roundtripstockham.c"
#undef main
#undef printf

static void bytes(const char *name, const uint8_t *v, size_t n) {
    FILE *f = fopen(name, "w");
    if (!f) { perror(name); exit(1); }
    for (size_t i=0; i<n; i++) fprintf(f, "%02x\n", v[i]);
    if (fclose(f)) exit(1);
}
static void polys(const char *name, const int16_t *v, size_t n) {
    FILE *f = fopen(name, "w");
    if (!f) { perror(name); exit(1); }
    for (size_t i=0; i<n; i++) {
        int x = v[i] % 3329;
        if (x < 0) x += 3329;
        fprintf(f, "%03x\n", x);
    }
    if (fclose(f)) exit(1);
}
static uint32_t rng = 0x20351a7u;
static uint8_t random_byte(void) {
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return (uint8_t)rng;
}
// Find a valid key whose final matrix polynomial has 252..255 accepted
// candidates after three blocks, with 252 already present before the tail.
// This targets the old "coefficient 252 means done" continuation bug.
static void partial_final_seed(uint8_t d[32], unsigned k) {
    for (uint32_t attempt=0; attempt<2000000; attempt++) {
        for (unsigned b=0;b<4;b++) d[b]=(uint8_t)(attempt>>(8*b));
        uint8_t input[33], digest[64], seed[34], block[504];
        memcpy(input,d,32);input[32]=(uint8_t)k;
        sha3_512(input,33,digest);
        memcpy(seed,digest,32);seed[32]=(uint8_t)(k-1);seed[33]=(uint8_t)(k-1);
        keccak_ctx_t xof;
        shake128_init(&xof);shake128_absorb(&xof,seed,34);shake128_finalize(&xof);
        shake128_squeeze(&xof,block,sizeof block);
        unsigned accepted=0, before_tail=0;
        for (unsigned off=0;off<sizeof block;off+=3) {
            unsigned a=block[off] | ((block[off+1]&15u)<<8);
            unsigned b=(block[off+1]>>4) | ((unsigned)block[off+2]<<4);
            accepted+=(a<3329)+(b<3329);
            if (off+3==492) before_tail=accepted;
        }
        if (before_tail>=252 && accepted<256) {
            printf("Targeted partial final beat k=%u search=%u prefix=%u total=%u\n",k,attempt,before_tail,accepted);
            return;
        }
    }
    fprintf(stderr,"Could not find partial-final-beat seed\n");exit(1);
}
#ifndef GEN_ENCAP_LIBRARY
int main(void) {
    const mlkem_params_t *params[3] = {&MLKEM_1024, &MLKEM_512, &MLKEM_768};
    for (unsigned test=0; test<99; test++) {
        const mlkem_params_t *p = params[test%3];
        unsigned k = p->k, pattern=test/3;
        uint8_t d[32], z[32], m[32], pk[1568], sk[3168], ct[1568], ss[32], recovered[32];
        for (unsigned i=0; i<32; i++) {
            d[i] = pattern==0 ? i : pattern==1 ? 0 : pattern==2 ? 255 : random_byte();
            z[i] = pattern==0 ? 31-i : random_byte();
            m[i] = pattern==0 ? 0 : pattern==1 ? 255 : pattern==2 ? (1u << (i%8)) : random_byte();
        }
        if (test>=96) partial_final_seed(d,k);
        mlkem_keygen(p, d, z, pk, sk);
        if (!mlkem_encapsulate(p, m, pk, ct, ss)) return 1;
        mlkem_decapsulate(p, sk, ct, recovered);
        if (memcmp(ss, recovered, 32)) { fprintf(stderr,"Reference roundtrip failed %u\n",test); return 1; }
        char name[80];
#define WRITE_BYTES(suffix, data, n) do { snprintf(name,sizeof name,"enc_%02u_" suffix ".hex",test); bytes(name,data,n); } while(0)
        WRITE_BYTES("d",d,32); WRITE_BYTES("z",z,32); WRITE_BYTES("m",m,32);
        WRITE_BYTES("pk",pk,PKE_PK_LEN(k)); WRITE_BYTES("ct",ct,PKE_CT_LEN(k,p->du,p->dv)); WRITE_BYTES("ss",ss,32);
        uint8_t g[64], gr[64];
        memcpy(g,m,32); sha3_256(pk,PKE_PK_LEN(k),g+32); sha3_512(g,64,gr);
        WRITE_BYTES("h",g+32,32); WRITE_BYTES("coins",gr+32,32);
        int16_t r[1024], e1[1024], e2[256], at[4096], t[1024], uv[1280];
        generate_vector(r,k,p->eta1,gr+32,0);
        generate_vector(e1,k,2,gr+32,k);
        generate_vector(e2,1,2,gr+32,2*k);
        generate_matrix(at,k,pk+k*384,1);
#define WRITE_POLYS(suffix, data, n) do { snprintf(name,sizeof name,"enc_%02u_" suffix ".hex",test); polys(name,data,n); } while(0)
        WRITE_POLYS("r",r,k*256); WRITE_POLYS("e1",e1,k*256); WRITE_POLYS("e2",e2,256); WRITE_POLYS("at",at,k*k*256);
        polyvec_ntt(r,k); WRITE_POLYS("rhat",r,k*256);
        polyvec_decode(pk,k,12,t);
        matrix_vec_mul(at,r,uv,k); vec_vec_mul(t,r,uv+k*256,k);
        WRITE_POLYS("uvhat",uv,(k+1)*256);
        polyvec_intt(uv,k+1); WRITE_POLYS("uvintt",uv,(k+1)*256);
        printf("Stockham case %02u k=%u pattern=%u verified by decapsulation\n",test,k,pattern);
    }
    return 0;
}
#endif
