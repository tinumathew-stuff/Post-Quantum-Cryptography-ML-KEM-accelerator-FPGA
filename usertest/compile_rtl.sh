#!/bin/bash
set -e

# Always run from the project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Source Vivado toolchain
source /home/tinu/Binaries/bubo/2025.2/Vivado/settings64.sh

mkdir -p usertest/build
cd usertest/build

echo "=================================================================="
echo " Compiling ML-KEM RTL Modules with Vivado xvlog"
echo "=================================================================="

xvlog -sv \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/field_add/rtl/field_add.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/field_sub/rtl/field_sub.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/hash_sampler/rtl/keccak_f1600.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/hash_sampler/rtl/mlkem_hash_sampler.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/ntt_intt/rtl/mlkem_butterfly.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/ntt_intt/rtl/mlkem_ntt_intt.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/mul_stream/rtl/mlkem_mul_stream.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/new_poly_encode_decode_1/rtl/poly_decode.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/new_poly_encode_decode_1/rtl/poly_encode.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/new_compress_decompress/rtl/mlkem_poly_compress.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/new_compress_decompress/rtl/mlkem_poly_decompress.sv" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/accel_core/rtl/sha3_256_core.sv" \
    -i "${PROJECT_ROOT}/mlkem_hpka_accelerator/accel_core/rtl" \
    "${PROJECT_ROOT}/mlkem_hpka_accelerator/accel_core/rtl/mlkem_keygen_top.sv"

echo "RTL Compilation Complete!"
