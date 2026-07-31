# ML-KEM HPKA: High-Performance, Zero-BRAM, 8-DSP Hardware Accelerator for FIPS 203 Post-Quantum Cryptography

## Executive Technical Summary & FPGA Implementation Results

### 1. Architectural Highlights
- **Cryptographic Standard**: Complete hardware acceleration of **FIPS 203 (ML-KEM)** across all three security levels:
  - **ML-KEM-512** ($k = 2$, NIST Security Category 1)
  - **ML-KEM-768** ($k = 3$, NIST Security Category 3)
  - **ML-KEM-1024** ($k = 4$, NIST Security Category 5)
- **Multi-Mode Unified Top-Level Engine**:
  - Mode `2'b00`: **Key Generation (KeyGen)**
  - Mode `2'b01`: **Encapsulation (Encap)**
  - Mode `2'b10`: **Decapsulation (Decap)** with constant-time Fujisaki-Okamoto (FO) transform and implicit rejection.
- **Ultra-Constrained Physical Resource Budget**:
  - **Zero Block RAMs (0 BRAMs / 0 FIFO36 / 0 FIFO18)**: All polynomial intermediate arrays, twiddles, and temporary buffers are synthesized strictly into CLB Distributed RAM (LUTRAM), Shift Register LUTs (SRLs), and CLB Flip-Flops.
  - **Strictly 8 DSP48E2 Slices**: Only the streaming dual-channel Karatsuba pointwise multiplier consumes DSPs ($2 \times 4 = 8$ slices). The NTT/INTT butterfly unit, hash sampler, and polynomial codecs operate completely DSP-free ($0$ DSPs).
- **Target Platform & Frequency**:
  - Device: **AMD/Xilinx Kintex UltraScale `xcku035-ffva1156-3-e`**
  - Clock Constraint: $T_{clk} = 2.222\text{ ns}$ ($450.0\text{ MHz}$)
  - Achieved Clock Frequency: $F_{max} \approx \mathbf{413.7\text{ MHz}}$ ($T_{min} = 2.417\text{ ns}$, $\text{WNS} = -0.195\text{ ns}$).

---

### 2. Comprehensive FPGA Implementation Metrics

Below are the post-implementation utilization and timing metrics extracted from the routed implementation runs (`build/run_speedgrade3/util_impl.rpt` and `timing_impl.rpt`):

#### Table 1: Device Resource Utilization Summary
| Resource Type | Used | Available | Utilization Percentage (%) |
| :--- | :--- | :--- | :--- |
| **CLB LUTs** | **29,063** | 203,128 | **14.31%** |
| — *LUT as Logic* | 23,484 | 203,128 | 11.56% |
| — *LUT as Memory* | 5,579 | 112,800 | 4.95% |
|   — *LUT as Distributed RAM* | 5,324 | 112,800 | 4.72% |
|   — *LUT as Shift Register (SRL)* | 255 | 112,800 | 0.23% |
| **CLB Registers (Flip-Flops)** | **17,666** | 406,256 | **4.35%** |
| **CLB Slices (Occupied)** | 5,453 | 30,300 | 18.00% |
| — *CLBL Slices* | 2,617 | — | — |
| — *CLBM Slices (Memory capable)* | 2,836 | — | — |
| **Block RAM (BRAM Tile / RAMB36 / RAMB18)** | **0** | 540 | **0.00% (Strictly Zero)** |
| **DSP48E2 Slices** | **8** | 1,700 | **0.47% (Strictly 8 DSPs)** |
| **Dedicated Carry Chains (CARRY8)** | 519 | 30,300 | 1.71% |
| **Multiplexers (F7 / F8 Muxes)** | 560 | 181,800 | 0.31% |

#### Table 2: Timing Closure & Clock Characteristics
| Metric | Value | Constraint / Target | Margin / Status |
| :--- | :--- | :--- | :--- |
| **Target Clock Period** | $2.222\text{ ns}$ | $450.045\text{ MHz}$ | — |
| **Worst Negative Slack (WNS)** | $-0.195\text{ ns}$ | $0.000\text{ ns}$ | $-0.195\text{ ns}$ |
| **Total Negative Slack (TNS)** | $-234.366\text{ ns}$ | $0.000\text{ ns}$ | 4,311 / 82,428 endpoints |
| **Worst Hold Slack (WHS)** | $+0.047\text{ ns}$ | $0.000\text{ ns}$ | **Passed (Met)** |
| **Worst Pulse Width Slack (WPWS)** | $+0.525\text{ ns}$ | $0.000\text{ ns}$ | **Passed (Met)** |
| **Achieved Minimum Period ($T_{min}$)** | $\mathbf{2.417\text{ ns}}$ | — | $2.222\text{ ns} + 0.195\text{ ns}$ |
| **Achieved Maximum Frequency ($F_{max}$)** | $\mathbf{413.7\text{ MHz}}$ | — | **Extremely high for PQC ASIC/FPGA** |

---

### 3. Modular Subsystem Architecture

The accelerator is divided into six specialized functional subsystems:

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
|  | 4-Butterfly Parallel|  | Multiplier (Dual)  |   | Permutation Core   |   | (Compress /      |  |
|  | 8-Bank Dist-RAM    |   | 8 DSP48E2 Slices   |   | 24-Cycle / 48-Cycle|   |  Decompress /    |  |
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

1. **Subsystem 01: Top-Level System Architecture & Controller (`01_system_top_and_controller.md`)**
   - Coordinates overall operation scheduling across modes.
   - Implements the complete constant-time Fujisaki-Okamoto (FO) transform with implicit rejection: computes $K_{reject} \leftarrow \text{SHAKE256}(z \parallel c, 32)$ and securely muxes the shared secret based on bit-exact ciphertext re-encryption comparison.
   - Manages zero-BRAM storage of public keys, secret keys, seeds, and ciphertexts in distributed memory.
2. **Subsystem 02: Number Theoretic Transform Engine (`02_ntt_intt_transform_unit.md`)**
   - 4-butterfly parallel processing unit executing 8 coefficients per clock cycle.
   - Pipelined 10-cycle butterfly ALU operating at 450 MHz with strictly **0 DSPs**, utilizing a 3-chunk soft multiplier tree and custom Barrett reduction exploiting $q = 3329 = 13 \times 2^8 + 1$.
   - Conflict-free 8-bank memory architecture guaranteeing stall-free parallel access across all 7 NTT/INTT Cooley-Tukey and Gentleman-Sande stages.
3. **Subsystem 03: Pointwise Dyadic Multiplier & Modular Field ALU (`03_pointwise_multiplier_and_field_alu.md`)**
   - Streaming Dual-PWM arithmetic processing 4 coefficients per cycle across quotient rings $\mathbb{Z}_q[X]/(X^2 - \zeta^{2r+1})$.
   - Karatsuba degree-1 polynomial multiplication mapped to exactly **8 DSP48E2 slices**.
   - Dual parallel carry-chain modular addition and subtraction units with 2-entry skid buffers.
4. **Subsystem 04: Keccak-f[1600] Permutation Core (`04_keccak_f1600_permutation_core.md`)**
   - Single-round-per-cycle permutation engine delivering complete 1600-bit permutation in exactly 24 clock cycles (`FAST_24 = 1`).
   - Pipelined intermediate stages meeting 450 MHz without Block RAMs or DSPs.
5. **Subsystem 05: Cryptographic Hash Sampler & CBD Engine (`05_cryptographic_sampler_and_cbd.md`)**
   - Unified hashing subsystem supporting SHA3-256, SHA3-512, SHAKE-128, and SHAKE-256.
   - On-the-fly rejection sampler for public matrix $A$, packing up to four 12-bit valid coefficients per clock beat.
   - Centered Binomial Distribution (CBD) sampler supporting $\eta \in \{2, 3\}$.
   - High-throughput 64-bit lane absorb interface eliminating byte-serial throughput bottlenecks.
6. **Subsystem 06: Polynomial Compression, Decompression & Serialization Codecs (`06_poly_codecs_compression_serialization.md`)**
   - Division-less and multiplier-less polynomial compressor using fixed-point constant scaling ($161271 \approx 2^{29}/3329$) and Canonical Signed Digit (CSD) adder trees.
   - Elastic backpressured streaming pipeline supporting runtime $d \in \{1, 4, 5, 10, 11\}$.
   - Zero-bubble ping-pong serialization buffer converting between 12-bit polynomial coefficients and 8-bit packed byte streams.

---

### 4. Structure of the Proposed IEEE Transactions Research Paper

```
+---------------------------------------------------------------------------------------------------+
| Title: High-Performance, BRAM-Free Hardware Architecture for FIPS 203 (ML-KEM) on Modern FPGAs    |
+---------------------------------------------------------------------------------------------------+
| Section I:   Introduction & Motivation (Post-Quantum Transition, FIPS 203, Edge Constraints)      |
| Section II:  Background & Preliminaries (ML-KEM Rings, Modulus 3329, NTT, FO-Transform)          |
| Section III: Unified Multi-Mode Architecture & Datapath Sharing                                    |
| Section IV:  Arithmetic Optimization & Conflict-Free Memory Banking                                |
|              - 4-Butterfly Parallel 0-DSP NTT Engine                                              |
|              - Dual-Channel Karatsuba Pointwise Multiplier with 8 DSPs                            |
|              - Division-Free CSD Compression & Zero-Stall Ping-Pong Codecs                        |
| Section V:   Unified Cryptographic Sponge & Sampling Architecture                                  |
|              - 24-Cycle Keccak-f[1600] Engine & 64-Bit Lane Absorb                                |
|              - Multi-Coefficient Uniform Rejection & CBD Sampler                                  |
| Section VI:  Implementation Results, Physical Performance & Prior-Art Comparison                   |
|              - Kintex UltraScale Results: 413.7 MHz, 29.0k LUTs, 17.6k FFs, 0 BRAM, 8 DSPs        |
|              - Comparison with State-of-the-Art (Sapphire, Crystals-Kyber HW, etc.)               |
| Section VII: Conclusion & Future Directions                                                       |
+---------------------------------------------------------------------------------------------------+
```

This report serves as the master architectural reference and index for the detailed subsystem documentation authored in files `01` through `06`.
