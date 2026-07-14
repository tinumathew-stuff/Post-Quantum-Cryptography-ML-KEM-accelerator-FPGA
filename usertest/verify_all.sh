#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Source Vivado toolchain
source /home/tinu/Binaries/bubo/2025.2/Vivado/settings64.sh

echo "================================================================================"
echo " Starting Full ML-KEM User Test Suite (All Modes & Operations)"
echo "================================================================================"

# 1. Compile RTL
echo "[1/4] Compiling Accelerator RTL..."
"${SCRIPT_DIR}/compile_rtl.sh" > /dev/null

# 2. Compile and Run C Reference Programs
echo "[2/4] Compiling and Running C Reference Programs..."
"${SCRIPT_DIR}/c_ref/run_c_tests.sh"

# 3. Run Vivado SystemVerilog Simulations
echo "[3/4] Running Vivado RTL Simulations for all 9 Standalone Testbenches..."
TBS=(
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

for tb in "${TBS[@]}"; do
    echo "  -> Simulating ${tb}..."
    "${SCRIPT_DIR}/run_sim.sh" "${tb}" > /dev/null
done

# 4. Compare C Traces vs RTL Simulation Traces
echo "[4/4] Cross-Verifying Traces (C Reference vs. Vivado RTL Simulation)..."
echo "================================================================================"
printf "%-18s | %-12s | %-12s | %-17s | %-10s\n" "Operation" "Mode" "Cycles" "Bit-Exact C Match" "Status"
echo "--------------------------------------------------------------------------------"

ALL_PASSED=1

check_test() {
    local op="$1"
    local mode="$2"
    local tb_name="tb_${op}_${mode}"
    local c_name="test_${op}_${mode}"
    local sim_log="${SCRIPT_DIR}/sim_logs/${tb_name}.log"
    local c_log="${SCRIPT_DIR}/c_ref/traces/${c_name}.log"

    # Extract cycle count from sim log
    local cycles=$(grep -oP "(?:Latency:\s*|Execution Latency:\s*|completed in\s*)\K[0-9]+" "${sim_log}" | head -n 1)
    if [ -z "${cycles}" ]; then
        cycles="N/A"
    fi

    # Extract [C-STYLE KAT TRACE] block using robust awk
    local sim_trace=$(awk '/\[C-STYLE KAT TRACE\]/{flag=1; count=0} flag{print; if (/====/) count++; if (count==2) flag=0}' "${sim_log}")
    local c_trace=$(awk '/\[C-STYLE KAT TRACE\]/{flag=1; count=0} flag{print; if (/====/) count++; if (count==2) flag=0}' "${c_log}")

    if [ -n "${sim_trace}" ] && [ "${sim_trace}" = "${c_trace}" ]; then
        printf "%-18s | ML-KEM-%-5s | %-12s | %-17s | \033[1;32mPASS\033[0m\n" "${op^^}" "${mode}" "${cycles}" "100% BIT-EXACT"
    else
        printf "%-18s | ML-KEM-%-5s | %-12s | %-17s | \033[1;31mFAIL\033[0m\n" "${op^^}" "${mode}" "${cycles}" "MISMATCH"
        ALL_PASSED=0
    fi
}

for op in "keygen" "encap" "decap"; do
    for mode in "512" "768" "1024"; do
        check_test "${op}" "${mode}"
    done
done

echo "================================================================================"
if [ ${ALL_PASSED} -eq 1 ]; then
    echo -e "\033[1;32mALL 9 STANDALONE TESTS PASSED AND 100% BIT-EXACT MATCH WITH C REFERENCE!\033[0m"
    echo "================================================================================"
    exit 0
else
    echo -e "\033[1;31mREGRESSION FAILED: ONE OR MORE TESTS MISMATCHED!\033[0m"
    echo "================================================================================"
    exit 1
fi
