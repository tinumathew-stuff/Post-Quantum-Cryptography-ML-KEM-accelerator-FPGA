#!/bin/bash
set -e

# Ensure we operate strictly within the repository workspace
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

mkdir -p traces

echo "=================================================================="
echo " Compiling and Executing ML-KEM C Reference Programs"
echo " Target Directory: ${SCRIPT_DIR}"
echo "=================================================================="

PROGRAMS=(
    "test_keygen_512"
    "test_keygen_768"
    "test_keygen_1024"
    "test_encap_512"
    "test_encap_768"
    "test_encap_1024"
    "test_decap_512"
    "test_decap_768"
    "test_decap_1024"
)

TOTAL_ERRORS=0

for PROG in "${PROGRAMS[@]}"; do
    echo -n "[COMPILE] ${PROG}.c -> ${PROG} ... "
    gcc -O3 -Wall -Wextra "${PROG}.c" -o "${PROG}"
    echo "OK"

    echo -n "[RUN]     ${PROG} -> traces/${PROG}.log ... "
    ./"${PROG}" > "traces/${PROG}.log"
    if [ $? -eq 0 ]; then
        echo "PASS (Trace Log Generated)"
    else
        echo "FAIL"
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi
done

echo "=================================================================="
if [ ${TOTAL_ERRORS} -eq 0 ]; then
    echo " ALL 9 C REFERENCE PROGRAMS COMPILED AND EXECUTED SUCCESSFULLY!"
    echo " Traces saved in: ${SCRIPT_DIR}/traces/"
    echo "=================================================================="
    exit 0
else
    echo " ENCOUNTERED ${TOTAL_ERRORS} ERRORS DURING EXECUTION!"
    echo "=================================================================="
    exit 1
fi
