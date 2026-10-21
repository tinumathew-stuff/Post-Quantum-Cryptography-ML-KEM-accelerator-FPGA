#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Source Vivado toolchain
source /home/tinu/Binaries/bubo/2025.2/Vivado/settings64.sh

echo "=================================================================="
echo " STEP 1: Running Synthesis & Implementation Flow in Vivado"
echo "=================================================================="
vivado -mode batch \
    -source post_synth_impl_verification/run_synth_impl.tcl \
    -log post_synth_impl_verification/build/vivado.log \
    -jou post_synth_impl_verification/build/vivado.jou

echo "=================================================================="
echo " STEP 2: Running Post-Synthesis Result Verification"
echo "=================================================================="
bash post_synth_impl_verification/run_post_synth_sim.sh

echo "=================================================================="
echo " STEP 3: Running Post-Implementation Result Verification"
echo "=================================================================="
bash post_synth_impl_verification/run_post_impl_sim.sh

echo "=================================================================="
echo " ALL POST-SYNTHESIS & POST-IMPLEMENTATION VERIFICATIONS PASSED!"
echo "=================================================================="
