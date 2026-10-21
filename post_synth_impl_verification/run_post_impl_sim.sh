#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Source Vivado toolchain
source /home/tinu/Binaries/bubo/2025.2/Vivado/settings64.sh

SIM_DIR="${PROJECT_ROOT}/post_synth_impl_verification/build_post_impl_sim"
LOG_DIR="${PROJECT_ROOT}/post_synth_impl_verification/logs"
NETLIST="${PROJECT_ROOT}/post_synth_impl_verification/build/post_impl_netlist.v"

mkdir -p "${SIM_DIR}"
mkdir -p "${LOG_DIR}"

cd "${SIM_DIR}"

# Copy vectors into local sim dir for $readmemh
cp -n "${PROJECT_ROOT}/post_synth_impl_verification/vectors/"* . 2>/dev/null || true

echo "=================================================================="
echo " Compiling Xilinx glbl and Post-Implementation Netlist"
echo "=================================================================="
xvlog "${XILINX_VIVADO}/data/verilog/src/glbl.v"
xvlog "${NETLIST}"

TESTBENCHES=(
    "tb_keygen_512"
    "tb_keygen_768"
    "tb_keygen_1024"
    "tb_encap_512"
    "tb_encap_768"
    "tb_encap_1024"
    "tb_decap_512"
    "tb_decap_768"
    "tb_decap_1024"
)

TOTAL_PASS=0
TOTAL_FAIL=0

for TB in "${TESTBENCHES[@]}"; do
    echo "=================================================================="
    echo " [POST-IMPLEMENTATION] Running: ${TB}"
    echo "=================================================================="

    xvlog -sv "${PROJECT_ROOT}/post_synth_impl_verification/tb/${TB}.sv"
    xelab -L unisims_ver -L unimacro_ver "${TB}" glbl -s "${TB}_post_impl_sim"
    xsim "${TB}_post_impl_sim" -R | tee "${LOG_DIR}/post_impl_${TB}.log"

    if grep -q "\[PASS\]" "${LOG_DIR}/post_impl_${TB}.log"; then
        echo "--> RESULT: ${TB} PASSED POST-IMPLEMENTATION VERIFICATION"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        echo "--> RESULT: ${TB} FAILED POST-IMPLEMENTATION VERIFICATION"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
done

echo "=================================================================="
echo " POST-IMPLEMENTATION VERIFICATION SUMMARY"
echo " Passed: ${TOTAL_PASS} / ${#TESTBENCHES[@]}"
echo " Failed: ${TOTAL_FAIL} / ${#TESTBENCHES[@]}"
echo "=================================================================="

if [ ${TOTAL_FAIL} -ne 0 ]; then
    echo "Post-implementation verification encountered failures!"
    exit 1
fi

echo "All post-implementation tests passed successfully!"
exit 0
