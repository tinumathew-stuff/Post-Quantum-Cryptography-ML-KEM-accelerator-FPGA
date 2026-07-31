#define GEN_ENCAP_LIBRARY
#include "gen_encap_kats.c"

int main(void) {
    const mlkem_params_t *params[3] = {&MLKEM_1024,&MLKEM_512,&MLKEM_768};
    for (unsigned id=0;id<99;id++) {
        const mlkem_params_t *p=params[id%3];
        unsigned k=p->k, pattern=id/3, ctlen=PKE_CT_LEN(k,p->du,p->dv);
        uint8_t d[32],z[32],m[32],pk[1568],sk[3168],ct[1568],ss[32],original[32];
        for (unsigned i=0;i<32;i++) {
            d[i]=pattern==0 ? i : pattern==1 ? 0 : pattern==2 ? 255 : random_byte();
            z[i]=pattern==0 ? 31-i : random_byte();
            m[i]=pattern==0 ? 0 : pattern==1 ? 255 : pattern==2 ? (1u<<(i%8)) : random_byte();
        }
        if (id>=96) partial_final_seed(d,k);
        mlkem_keygen(p,d,z,pk,sk);
        if (!mlkem_encapsulate(p,m,pk,ct,original)) return 1;
        char name[100];
#define DB(suffix,data,n) do { snprintf(name,sizeof name,"dec_%02u_" suffix ".hex",id); bytes(name,data,n); } while(0)
#define DP(suffix,data,n) do { snprintf(name,sizeof name,"dec_%02u_" suffix ".hex",id); polys(name,data,n); } while(0)
        DB("dk",sk,768*k+96); DB("d",d,32); DB("z",z,32);
        for (unsigned variant=0;variant<5;variant++) {
            if (variant==1) ct[0]^=1;
            if (variant==2) { ct[0]^=1; ct[k*p->du*32-1]^=128; }
            if (variant==3) { ct[k*p->du*32-1]^=128; ct[ctlen-1]^=128; }
            if (variant==4) for (unsigned i=0;i<ctlen;i++) ct[i]=random_byte();
            mlkem_decapsulate(p,sk,ct,ss);
            if (variant==0 && memcmp(original,ss,32)) return 1;
            snprintf(name,sizeof name,"dec_%02u_%u_ct.hex",id,variant);bytes(name,ct,ctlen);
            snprintf(name,sizeof name,"dec_%02u_%u_ss.hex",id,variant);bytes(name,ss,32);
            uint8_t recovered[32],reject[32],g[64],gr[64];
            kpke_decrypt(p,sk,ct,recovered);
            keccak_ctx_t xof; shake256_init(&xof);shake256_absorb(&xof,z,32);
            shake256_absorb(&xof,ct,ctlen);shake256_finalize(&xof);shake256_squeeze(&xof,reject,32);
            if (variant!=0 && memcmp(reject,ss,32)) return 1;
            memcpy(g,recovered,32);memcpy(g+32,sk+768*k+32,32);sha3_512(g,64,gr);
            snprintf(name,sizeof name,"dec_%02u_%u_m.hex",id,variant);bytes(name,recovered,32);
            snprintf(name,sizeof name,"dec_%02u_%u_j.hex",id,variant);bytes(name,reject,32);
            snprintf(name,sizeof name,"dec_%02u_%u_g.hex",id,variant);bytes(name,gr,64);
            int16_t u[1024],v[256],s[1024],w[256];
            polyvec_decode(ct,k,p->du,u);polyvec_decompress(u,k,p->du);
            poly_decode(ct+k*p->du*32,v,p->dv);poly_decompress(v,p->dv);
            snprintf(name,sizeof name,"dec_%02u_%u_u.hex",id,variant);polys(name,u,k*256);
            snprintf(name,sizeof name,"dec_%02u_%u_v.hex",id,variant);polys(name,v,256);
            polyvec_ntt(u,k);polyvec_decode(sk,k,12,s);vec_vec_mul(s,u,w,k);
            snprintf(name,sizeof name,"dec_%02u_%u_uhat.hex",id,variant);polys(name,u,k*256);
            snprintf(name,sizeof name,"dec_%02u_%u_what.hex",id,variant);polys(name,w,256);
            ntt_inverse(w);
            snprintf(name,sizeof name,"dec_%02u_%u_w.hex",id,variant);polys(name,w,256);
        }
        printf("Stockham decapsulation case %u k=%u: valid + four rejection vectors\n",id,k);
    }
    return 0;
}
