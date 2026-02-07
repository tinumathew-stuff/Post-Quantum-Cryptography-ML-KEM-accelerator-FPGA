# ML-KEM HPKA: High-Performance, Zero-BRAM, 8-DSP Hardware Accelerator for FIPS 203 PQC

## 1. Overview
This repository hosts the complete SystemVerilog implementation and verification environment for the **ML-KEM HPKA (High-Performance Public Key Accelerator)**, compliant with the official NIST **FIPS 203** Post-Quantum Cryptography (PQC) standard.

The accelerator provides unified hardware acceleration for all three security categories:
- **ML-KEM-512** ($k = 2$, NIST Category 1)
- **ML-KEM-768** ($k = 3$, NIST Category 3)
- **ML-KEM-1024** ($k = 4$, NIST Category 5)

## 2. Key Architecture Innovations
- **Multi-Mode Unified Core**: Supports **KeyGen** (`2'b00`), **Encap** (`2'b01`), and **Decap** (`2'b10`) with constant-time Fujisaki-Okamoto (FO) transform and implicit rejection.
- **Zero Block RAM (0 BRAMs / 0 FIFO36 / 0 FIFO18)**: Intermediate polynomials, matrix buffers, and twiddles are synthesized entirely into CLB Distributed RAM (LUTRAM) and Shift Register LUTs (SRLs).
- **Strictly 8 DSP48E2 Slices**: Multiplier subsystem utilizes a streaming dual-channel Karatsuba pointwise multiplier consuming exactly 8 DSPs ($2 \times 4$). The NTT butterfly unit, hash sampler, and codecs operate completely DSP-free ($0$ DSPs).
- **Target Platform & Frequency**:
  - Device: **AMD/Xilinx Kintex UltraScale `xcku035-ffva1156-3-e`**
  - Clock Target: $450.0\text{ MHz}$ ($T_{clk} = 2.222\text{ ns}$)
  - Achieved Clock Frequency: $F_{max} \approx 413.7\text{ MHz}$ ($T_{min} = 2.417\text{ ns}$)

## 3. Directory Layout
```
├── architectural_diagrams/     # TikZ / PGFPlots source files and rendered diagrams
├── build/                      # Vivado non-project batch flow scripts and constraints
├── docs/                       # In-depth architectural module documentation
├── mlkem_hpka_accelerator/     # SystemVerilog RTL modules and unit testbenches
├── paper/                      # IEEE conference/journal LaTeX paper sources and figures
├── scripts/                    # Python analysis and verification scripts
└── usertest/                   # Integration testbenches and FIPS 203 KAT vectors
```

## 4. Verification and Simulation
Run the complete automated verification regression test suite:
```bash
cd usertest
./verify_all.sh
```
