<div align="center">

# ML-KEM HPKA: High-Performance, Zero-BRAM, 8-DSP Hardware Accelerator

### Full Hardware Acceleration for NIST FIPS 203 Post-Quantum Cryptography (ML-KEM-512 / 768 / 1024)

[![Standard: FIPS 203](https://img.shields.io/badge/Standard-NIST%20FIPS%20203-blue.svg)](https://csrc.nist.gov/pubs/fips/203/final)
[![FPGA Target](https://img.shields.io/badge/FPGA-AMD%20Kintex%20UltraScale-orange.svg)](https://www.xilinx.com/products/silicon-devices/fpga/kintex-ultrascale.html)
[![Frequency](https://img.shields.io/badge/Fmax-413.7%20MHz-brightgreen.svg)]()
[![DSP Usage](https://img.shields.io/badge/DSP48E2-Strictly%208%20Slices-green.svg)]()
[![BRAM Usage](https://img.shields.io/badge/Block%20RAM-0%20(Zero--BRAM)-success.svg)]()
[![Verification](https://img.shields.io/badge/NIST%20KAT-100%25%20Verified-brightgreen.svg)]()
[![HDL](https://img.shields.io/badge/HDL-SystemVerilog%20%2F%20Verilog-blueviolet.svg)]()

</div>

---

## 📌 Executive Summary

**ML-KEM HPKA** (High-Performance Public Key Accelerator) is a unified, silicon-efficient cryptographic hardware engine implementing the official NIST **FIPS 203** Module-Lattice-Based Key-Encapsulation Mechanism (**ML-KEM**). 

The accelerator delivers full-speed hardware acceleration for all three security categories:
- **ML-KEM-512** ($k = 2$, NIST Category 1 / AES-128 equivalent)
- **ML-KEM-768** ($k = 3$, NIST Category 3 / AES-192 equivalent)
- **ML-KEM-1024** ($k = 4$, NIST Category 5 / AES-256 equivalent)

Designed specifically for modern FPGA and edge-SoC architectures, **ML-KEM HPKA** achieves an exceptional clock frequency of **413.7 MHz** on an **AMD/Xilinx Kintex UltraScale** (`xcku035-ffva1156-3-e`) while strictly adhering to an extreme resource budget: **0 Block RAMs** (synthesized purely into distributed LUTRAM/SRLs) and **strictly 8 DSP48E2 slices**.

---

## ⚡ Architectural Highlights

```
+---------------------------------------------------------------------------------------------------+
|                                 mlkem_keygen_top (Unified Controller)                             |
|                                                                                                   |
|  +--------------------+   +--------------------+   +--------------------+   +------------------+  |
|  |   Master Top FSM   |   |   Encap FSM        |   |   Decap FSM        |   |  FO-Transform &  |  |
|  |   (ST_0 to ST_9)   |   |   (EC_0 to EC_17)  |   |   (DC_0 to DC_5)   |   |  Implicit Reject |  |
|  +--------------------+   +--------------------+   +--------------------+   +------------------+  |
|                                                                                                   |
|  +--------------------+   +--------------------+   +--------------------+   +------------------+  |
|  | NTT / INTT Engine  |   | Pointwise Stream   |   | Keccak-f[1600]     |   | Poly Codecs      |  |
|  | 4-Butterfly Unit   |   | Multiplier (Dual)  |   | Permutation Core   |   | (Compress /      |  |
|  | 8-Bank Dist-RAM    |   | 8 DSP48E2 Slices   |   | 24-Cycle Permute   |   |  Decompress /    |  |
|  | 0 DSP (Soft Logic) |   | 24-Cycle Latency   |   | FAST_24 Execution  |   |  Encode/Decode)  |  |
|  +--------------------+   +--------------------+   +--------------------+   +------------------+  |
|                                                                                                   |
|  +----------------------------------------------------------------------+   +------------------+  |
|  |                  Unified Hash Sampler & CBD Engine                   |   | Modular Field    |  |
|  |  SHA3-256 / SHA3-512 / SHAKE-128 (Matrix A) / SHAKE-256 (CBD eta=2,3)|   | Arithmetic ALU   |  |
|  |  Fast 64-bit Lane Absorption & 4-Coeff Output Stream                |   | (Add / Sub 3329) |  |
|  +----------------------------------------------------------------------+   +------------------+  |
+---------------------------------------------------------------------------------------------------+
```

- **Triple-Mode Unified Datapath**: Native hardware acceleration for **KeyGen** (`2'b00`), **Encapsulation** (`2'b01`), and **Decapsulation** (`2'b10`).
- **Constant-Time Fujisaki-Okamoto (FO) Transform**: Hardened decapsulation datapath features constant-time ciphertext comparison and implicit rejection ($K_{reject} \leftarrow \text{SHAKE256}(z \parallel c, 32)$) to guard against timing and side-channel leakage.
- **Strictly Zero Block RAM (0 BRAM / 0 FIFO36 / 0 FIFO18)**: All polynomial intermediate arrays, twiddle factors, and matrix buffers reside in conflict-free CLB Distributed RAM (LUTRAM) and Shift Register LUTs (SRLs).
- **Strictly 8 DSP48E2 Slices**: Multiplier subsystem utilizes a streaming dual-channel Karatsuba pointwise multiplier consuming exactly 8 DSPs ($2 \times 4$). NTT/INTT butterfly unit, hash sampler, and codecs operate completely **DSP-free** ($0$ DSPs).
- **Ultra-High Clock Frequency**: Achieves $T_{min} = 2.417\text{ ns}$ (**$F_{max} = 413.7\text{ MHz}$**) post-implementation timing closure on Kintex UltraScale speedgrade-3.
- **High-Throughput Sponge Core**: 24-cycle Keccak-f[1600] permutation engine featuring 64-bit lane absorption, eliminating byte-serial throughput bottlenecks.

---

## 📊 Physical FPGA Implementation Metrics

Below are the post-implementation utilization and timing numbers extracted directly from the fully placed and routed Vivado implementation run (`build/run_speedgrade3/util_impl.rpt` and `timing_impl.rpt`) targeting the **AMD/Xilinx Kintex UltraScale `xcku035-ffva1156-3-e`**:

### Device Resource Utilization

| Resource Type | Used | Available | Utilization (%) | Design Constraint |
| :--- | :---: | :---: | :---: | :---: |
| **CLB LUTs** | **29,063** | 203,128 | **14.31%** | Target < 35,000 |
| — *LUT as Logic* | 23,484 | 203,128 | 11.56% | — |
| — *LUT as Memory (LUTRAM)* | 5,579 | 112,800 | 4.95% | Memory mapping |
| &nbsp;&nbsp;&nbsp;&nbsp;— *Distributed RAM* | 5,324 | 112,800 | 4.72% | 0 BRAM budget |
| &nbsp;&nbsp;&nbsp;&nbsp;— *Shift Register (SRL)* | 255 | 112,800 | 0.23% | Pipeline buffers |
| **CLB Registers (Flip-Flops)** | **17,666** | 406,256 | **4.35%** | — |
| **Occupied Slices** | 5,453 | 30,300 | 18.00% | Ultra-compact footprint |
| **Block RAM (RAMB36 / RAMB18)** | **0** | 540 | **0.00%** | **Strictly Zero** |
| **DSP48E2 Slices** | **8** | 1,700 | **0.47%** | **Strictly 8 DSPs** |
| **Dedicated Carry Chains (CARRY8)** | 519 | 30,300 | 1.71% | — |

### Timing & Frequency Performance

| Timing Metric | Achieved Value | Target Constraint | Margin / Status |
| :--- | :---: | :---: | :---: |
| **Target Clock Period ($T_{clk}$)** | $2.222\text{ ns}$ | $450.045\text{ MHz}$ | — |
| **Worst Negative Slack (WNS)** | $-0.195\text{ ns}$ | $0.000\text{ ns}$ | Near-closure at 450 MHz |
| **Achieved Minimum Period ($T_{min}$)** | **$2.417\text{ ns}$** | — | $2.222\text{ ns} + 0.195\text{ ns}$ |
| **Achieved Maximum Frequency ($F_{max}$)** | **$413.7\text{ MHz}$** | — | **Extremely high for PQC** |
| **Worst Hold Slack (WHS)** | **$+0.047\text{ ns}$** | $0.000\text{ ns}$ | **Passed (Met)** |
| **Worst Pulse Width Slack (WPWS)** | **$+0.525\text{ ns}$** | $0.000\text{ ns}$ | **Passed (Met)** |

---

## ⚙️ Core Subsystem Architecture

The accelerator is structured into modular, self-contained hardware subsystems located under `mlkem_hpka_accelerator/`:

```
mlkem_hpka_accelerator/
├── accel_core/             # Top-level integration, Encap & Decap FO-transform datapaths
├── field_add/              # Modular field adder in Z_q (q = 3329)
├── field_sub/              # Modular field subtractor in Z_q (q = 3329)
├── hash_sampler/           # SHAKE-128/256 sponge, SampleNTT rejection & CBD2/3 samplers
├── keccak_f1600/           # 24-cycle 1600-bit Keccak permutation core
├── mul_stream/             # 8-DSP streaming Karatsuba pointwise polynomial multiplier
├── new_compress_decompress/# Division-free CSD compression/decompression units
├── new_poly_encode_decode_1/# ByteEncode12 and ByteDecode12 polynomial serialization codecs
└── ntt_intt/               # 0-DSP 4-butterfly Cooley-Tukey NTT & Gentleman-Sande INTT unit
```

### 1. Unified Controller & Top Engine (`accel_core/`)
- Implements the master FSM coordinating KeyGen, Encapsulation, and Decapsulation.
- Manages on-the-fly public matrix $A$ expansion, noise sampling, NTT transformation, and constant-time Fujisaki-Okamoto verification.

### 2. Zero-DSP NTT/INTT Engine (`ntt_intt/`)
- Features a **4-butterfly parallel processing unit** delivering up to 8 coefficients per clock cycle.
- Operates at 413+ MHz with **zero DSPs** using a custom 3-chunk soft-multiplier tree and Barrett modular reduction optimized for $q = 3329 = 13 \times 2^8 + 1$.
- Implements an **8-bank memory architecture** that guarantees stall-free, conflict-free memory access across all 7 Cooley-Tukey and Gentleman-Sande stages.

### 3. 8-DSP Streaming Pointwise Multiplier (`mul_stream/`)
- Streaming dual-channel Karatsuba multiplier executing degree-1 polynomial base multiplications over $\mathbb{Z}_q[X]/(X^2 - \zeta^{2r+1})$.
- Mapped to **strictly 8 DSP48E2 slices** with pipelined Montgomery modular reduction.

### 4. Fast Keccak-f[1600] & Cryptographic Sampler (`keccak_f1600/`, `hash_sampler/`)
- Single-round-per-cycle permutation engine delivering full 1600-bit permutation in exactly 24 clock cycles.
- Combined rejection sampler for matrix $A$ (SampleNTT) and Centered Binomial Distribution (CBD) sampler supporting $\eta_1, \eta_2 \in \{2, 3\}$.
- Direct 64-bit word lane absorption for maximum throughput.

### 5. Serialization Codecs & Compression (`new_poly_encode_decode_1/`, `new_compress_decompress/`)
- Division-less polynomial compression utilizing fixed-point scaling factor ($161271 \approx 2^{29}/3329$) and Canonical Signed Digit (CSD) adders.
- Real-time serialization/deserialization between 12-bit coefficients and packed byte streams.

---

## 📂 Repository Directory Layout

```
├── architectural_diagrams/     # TikZ / PGFPlots source files and rendered diagrams
├── build/                      # Vivado batch synthesis scripts, constraints & timing reports
│   ├── constraints.xdc         # 450 MHz clock timing constraints
│   └── run_speedgrade3/        # Post-route reports (util_impl.rpt, timing_impl.rpt)
├── docs/                       # In-depth architectural module documentation
│   └── paper_modules/          # Detailed technical documentation for all subsystems
├── mlkem_hpka_accelerator/     # Synthesizable SystemVerilog RTL modules and unit TBs
├── paper/                      # IEEE conference/journal LaTeX paper sources and figures
│   ├── sections/               # LaTeX section files
│   ├── figures/                # TikZ figures and diagrams
│   └── main.pdf                # Compiled IEEE research paper
├── scripts/                    # Python analysis and synthesis log parser scripts
└── usertest/                   # Comprehensive testbenches & NIST FIPS 203 KAT vectors
    ├── c_ref/                  # C golden reference model and harness
    ├── vectors/                # Known Answer Test (KAT) hex vectors (512, 768, 1024)
    ├── compile_rtl.sh          # Vivado xelab compilation script
    ├── run_sim.sh              # Vivado xsim snapshot runner
    └── verify_all.sh           # Master regression script running all 9 testbenches
```

---

## 🚀 Quick Start & Verification

### Prerequisites
- **Vivado Simulator (`xsim` / `xelab`)** (version 2022.1 or newer recommended)
- **GCC / Clang** (for compiling the C reference verification model)
- **Python 3.8+** (for log parsing and analysis scripts)

### Running the End-to-End Test Suite
To compile the RTL and run the full suite of **9 testbenches** across all security levels (KeyGen, Encap, Decap for ML-KEM-512, 768, and 1024) against NIST Known Answer Tests:

```bash
cd usertest
chmod +x verify_all.sh compile_rtl.sh run_sim.sh
./verify_all.sh
```

### Running the C Golden Reference Model
```bash
cd usertest/c_ref
chmod +x run_c_tests.sh
./run_c_tests.sh
```

---

## 🛠️ FPGA Synthesis Flow

The design can be synthesized and implemented in non-project batch mode using Vivado:

```bash
cd build/run_speedgrade3
vivado -mode batch -source run_flow_speedgrade3.tcl
```

This runs synthesis, physical optimization, placement, routing, and generates post-route utilization and timing reports matching the published benchmarks.

---

## 📄 IEEE Research Paper

A complete research paper formatted for IEEE Transactions is included in `paper/`:
- **Manuscript source**: `paper/main.tex` (IEEEtran format)
- **Architectural diagrams**: `paper/figures/` (Vector TikZ/PGFPlots sources)
- **Pre-compiled PDF**: `paper/main.pdf`

---

## 👤 Author

**Tinu Mathew**  
- GitHub: [@tinumathew-stuff](https://github.com/tinumathew-stuff)  
- Email: [tinuone3@gmail.com](mailto:tinuone3@gmail.com)

---

## 📜 License

This project is licensed under the [MIT License](LICENSE) — see the LICENSE file for details.
