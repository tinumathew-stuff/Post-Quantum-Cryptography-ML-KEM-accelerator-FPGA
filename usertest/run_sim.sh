#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: ./run_sim.sh <testbench_name_without_extension>"
    echo "Example: ./run_sim.sh tb_keygen_512"
    exit 1
fi

TB_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Source Vivado toolchain
source /home/tinu/Binaries/bubo/2025.2/Vivado/settings64.sh

mkdir -p usertest/build
cd usertest/build

# Copy vectors into build directory so $readmemh finds them locally
cp -n "${PROJECT_ROOT}/usertest/vectors/"* . 2>/dev/null || true

echo "=================================================================="
echo " Compiling Testbench: ${TB_NAME}.sv"
echo "=================================================================="

xvlog -sv "${PROJECT_ROOT}/usertest/${TB_NAME}.sv"

echo "=================================================================="
echo " Elaborating Simulation Snapshot: ${TB_NAME}_sim"
echo "=================================================================="

xelab -debug typical "${TB_NAME}" -s "${TB_NAME}_sim"

echo "=================================================================="
echo " Running Simulation: ${TB_NAME}_sim"
echo "=================================================================="

xsim "${TB_NAME}_sim" -R | tee "${PROJECT_ROOT}/usertest/sim_logs/${TB_NAME}.log"
