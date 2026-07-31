# Rigorous Audit Report: Section I & Section II
**Document Under Audit:** `paper/sections/sec01_02_intro_prelims.md` (and `paper/mlkem_the proposed accelerator_ieee_paper.md` Lines 1–555)  
**Auditor:** Auditor Subagent 1 (Mathematical Rigor & FIPS 203 Standards Compliance)  
**Date of Audit:** October 14, 2026  
**Primary Standards & Ground Truth References:**
1. **NIST FIPS 203:** *Module-Lattice-Based Key-Encapsulation Mechanism Standard* (National Institute of Standards and Technology, Gaithersburg, MD, August 13, 2024), Sections 1, 2, 3, 4, 5, 6, 7, 8; Tables 1, 2, 3; Algorithms 1–21.
2. **SystemVerilog RTL Ground Truth:** `mlkem_accelerator/accel_core/rtl/mlkem_keygen_top.sv`, `mlkem_encap_datapath.svh`, `mlkem_decap_datapath.svh`, `mlkem_mul_stream.sv`, `mlkem_butterfly.sv`, `mlkem_poly_compress.sv`, `mlkem_hash_sampler.sv`, `keccak_f1600.sv`.
3. **Simulation Verification Testbenches:** `accel_core/tb/tb_mlkem_keygen_top.sv`, `accel_core/tb/tb_mlkem_encap.sv`, `accel_core/tb/tb_mlkem_decap.sv`.

---

## 1. Executive Summary & Verdict

### 1.1 Audit Scope
This audit conducts an exhaustive, line-by-line verification of:
- **Title, Abstract, and Section I (Introduction)**: Lines 1–130 of `paper/sections/sec01_02_intro_prelims.md`.
- **Section II (Preliminaries & FIPS 203 Mathematical Formulation)**: Lines 131–555 of `paper/sections/sec01_02_intro_prelims.md`.
- Corresponding lines 1–555 of the consolidated manuscript `paper/mlkem_the proposed accelerator_ieee_paper.md`.

### 1.2 Verdict
**VERDICT: PASS WITH MINOR REVISIONS**

**Summary Rationale:**
- **Mathematical Rigor:** The core algebraic, ring-theoretic, and number-theoretic formulations are **100% mathematically correct and rigorous**. The prime modulus $q = 3329 = 13 \times 2^8 + 1$, primitive 256-th root of unity $\zeta = 17$, the incomplete splitting of $X^{256} + 1$ into 128 quadratic polynomial factors modulo $(X^2 - \zeta^{2\cdot\text{BitRev}_7(i) + 1})$, dyadic base multiplication, Karatsuba formulation, and Barrett modular reductions are completely accurate.
- **Standards Compliance:** The algorithmic workflows faithfully track the final ratified **NIST FIPS 203 (August 13, 2024)** standard, including the critical post-draft updates:
  - Domain separation in seed expansion: $(\rho, \sigma) \leftarrow G(d \parallel k)$.
  - Public matrix generation indexing: $\hat{\mathbf{A}}[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, j, i))$ in KeyGen, and transposed sampling $\hat{\mathbf{A}}^T[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, i, j))$ in Encrypt.
  - Fujisaki-Okamoto transform with implicit rejection: $K_{reject} \leftarrow J(z \parallel c) = \text{SHAKE256}(z \parallel c, 32)$ and constant-time selection.
- **RTL Alignment:** All architectural claims (strictly 0 BRAMs, strictly 8 DSPs, 4-butterfly parallel soft-logic NTT engine, 24-cycle Keccak-$f[1600]$, CSD compression via $161271 \approx 2^{29}/3329$, 413.7 MHz operating frequency) were directly verified against the underlying SystemVerilog RTL modules.
- **Required Minor Revisions:**
  1. *Algorithm Citation Drift in Table I, Algorithm 1, and Algorithm 2:* The references in Table I and the headings of Algorithm 1 and Algorithm 2 reflect the algorithm numbering of the legacy CRYSTALS-Kyber Round 3 specification rather than the final published NIST FIPS 203 (e.g., `SampleNTT` is cited as Algorithm 5 instead of Algorithm 7; `SamplePolyCBD` as Algorithm 6 instead of Algorithm 8; `ByteEncode` as Algorithm 3 instead of Algorithm 5; `ByteDecode` as Algorithm 4 instead of Algorithm 6).
  2. *Introductory Count Typo in Section 1.2 (Line 46):* The text reads *"across four primary operational domains:"*, but then enumerates five distinct domains (1 to 5).
  3. *Academic Terminology Polish in Abstract (Line 10):* The text uses *"Fabricated and verified on an AMD Kintex UltraScale FPGA"*; standard IEEE nomenclature for field-programmable logic requires *"Implemented and verified on an AMD Kintex UltraScale FPGA"*, as "fabrication" strictly denotes ASIC foundry manufacturing.
  4. *Table I Reference Updates:* The citations for symmetric primitives ($G, H, J, \text{PRF}, \text{XOF}$) cite "Table 2" instead of "Section 2.5", and matrix dyadic product cites "Algorithm 16" instead of "Algorithm 13".

---

## 2. Checklist Verification & Ground-Truth Cross-Check

| Checklist Item | Standard / Specification | Verification Target (Paper Text) | Ground Truth Verification Result | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Prime Modulus $q$** | FIPS 203 Sec 2.1: $q = 3329 = 13 \times 2^8 + 1$ | Sec 1.2 (L49), Sec 2.1 (L138), Sec 2.2 (L151) | $13 \times 256 + 1 = 3328 + 1 = 3329$. Prime. Verified in RTL `mlkem_keygen_top.sv` L64 (`Q = 12'd3329`). | **CONFIRMED** |
| **Primitive Root $\zeta$** | FIPS 203 Sec 2.4: $\zeta = 17$, $\zeta^{256} \equiv 1$, $\zeta^{128} \equiv -1$ | Sec 2.2 (L155), Eq (5), Table I (L216) | $17^{256} \equiv 1 \pmod{3329}$, $17^{128} \equiv -1 \pmod{3329}$. Verified in RTL `mlkem_twiddle.svh`. | **CONFIRMED** |
| **Polynomial Degree $n$** | FIPS 203 Sec 2.1: $n = 256$ | Sec 2.1 (L138), Eq (1)-(2), Table I (L201) | Fixed degree $n = 256$. Verified in RTL registers (64 words $\times$ 4 coeffs = 256 coeffs). | **CONFIRMED** |
| **Ring Quotient $\mathcal{R}_q$** | FIPS 203 Sec 2.1: $\mathbb{Z}_q[X]/(X^{256}+1)$ | Sec 2.1 (L141), Eq (2) | Verified. Modular ring over cyclotomic polynomial $X^{256} + 1$. | **CONFIRMED** |
| **NTT Splitting Ring** | FIPS 203 Sec 2.4 Eq (2.8): 128 quadratic factors | Sec 2.2 (L158), Eq (6), Eq (8) | Incomplete splitting: $X^{256} + 1 \equiv \prod_{i=0}^{127} (X^2 - \zeta^{2\cdot\text{BitRev}_7(i)+1}) \pmod{3329}$. Exact match. | **CONFIRMED** |
| **Bit-Reversal Permutation** | FIPS 203 Sec 2.4: 7-bit reversal of $i \in [0, 127]$ | Sec 2.2 (L160), Eq (7) | Bit-reversal definition $\sum_{j=0}^6 b_j 2^{6-j}$ verified. Matches FIPS 203 Section 2.4. | **CONFIRMED** |
| **Dyadic Base Multiplication** | FIPS 203 Alg 11/12: $\text{BaseMul}(a_0, a_1, b_0, b_1, \gamma)$ | Sec 2.2.1 (L183), Eq (14) | $c_0 = a_0 b_0 + a_1 b_1 \gamma \pmod q$, $c_1 = a_0 b_1 + a_1 b_0 \pmod q$. Verified in RTL `mlkem_mul_stream.sv`. | **CONFIRMED** |
| **Karatsuba Formulation** | Karatsuba 3-mul decomposition of cross term | Sec 2.2.1 (L189), Eq (15) | $(a_0+a_1)(b_0+b_1) - a_0 b_0 - a_1 b_1$. Verified in RTL `mlkem_mul_stream.sv` (uses 3 mul per channel + 1 mul for $\gamma$). | **CONFIRMED** |
| **Module Ranks $k$** | FIPS 203 Table 1: $k \in \{2, 3, 4\}$ | Sec 2.4 Table II (L243) | $k = 2$ (512), $k = 3$ (768), $k = 4$ (1024). Verified in RTL `mlkem_keygen_top.sv` port `k[2:0]`. | **CONFIRMED** |
| **Noise Parameter $\eta_1$** | FIPS 203 Table 1: $\eta_1 = 3$ (512), $2$ (768), $2$ (1024) | Sec 2.4 Table II (L246) | Exact match. Verified in RTL `mlkem_encap_datapath.svh` L138 (`enc_s_eta3 = k_q == 2`). | **CONFIRMED** |
| **Noise Parameter $\eta_2$** | FIPS 203 Table 1: $\eta_2 = 2$ for all categories | Sec 2.4 Table II (L247) | Exact match. Verified in RTL `mlkem_hash_sampler.sv`. | **CONFIRMED** |
| **Compression $d_u$** | FIPS 203 Table 1: $d_u = 10$ (512, 768), $11$ (1024) | Sec 2.4 Table II (L248) | Exact match. Verified in RTL `mlkem_encap_datapath.svh` L71 (`enc_du_q <= (k == 4) ? 11 : 10`). | **CONFIRMED** |
| **Compression $d_v$** | FIPS 203 Table 1: $d_v = 4$ (512, 768), $5$ (1024) | Sec 2.4 Table II (L249) | Exact match. Verified in RTL `mlkem_encap_datapath.svh` L72 (`enc_dv_q <= (k == 4) ? 5 : 4`). | **CONFIRMED** |
| **Public Key Size ($ek$)** | FIPS 203 Table 2: $384k + 32$ (800, 1184, 1568 B) | Sec 2.4 Table II (L250) | Exact match. Verified in RTL `mlkem_keygen_top.sv` L220 (`ek_total_bytes = pke_bytes + 32`). | **CONFIRMED** |
| **Private Key Size ($dk$)** | FIPS 203 Table 2: $768k + 96$ (1632, 2400, 3168 B) | Sec 2.4 Table II (L251) | Exact match. Verified in RTL `tb_mlkem_keygen_top.sv` L54, L57, L60. | **CONFIRMED** |
| **Ciphertext Size ($c$)** | FIPS 203 Table 2: $32(k\cdot d_u + d_v)$ (768, 1088, 1568 B) | Sec 2.4 Table II (L252-254) | Exact match ($c_1$: 640, 960, 1408 B; $c_2$: 128, 128, 160 B). Verified in RTL testbench. | **CONFIRMED** |
| **Shared Secret Size ($K$)** | FIPS 203 Table 2: 32 Bytes (256 bits) | Sec 2.4 Table II (L255) | Exact match. Verified in RTL port `shared_secret[255:0]`. | **CONFIRMED** |
| **Decapsulation Failure Rate** | FIPS 203 Table 1/3: $2^{-139}, 2^{-164}, 2^{-174}$ | Sec 2.4 Table II (L256) | Exact theoretical bounds matching FIPS 203 and CRYSTALS-Kyber specifications. | **CONFIRMED** |
| **Domain Separation $G(d \parallel k)$** | FIPS 203 Alg 13 Step 1: $G(d \parallel k)$ with $k \in \mathbb{B}$ | Sec 2.6.1 (L366), Eq (22) | Exact match. Verified in RTL `mlkem_hash_sampler.sv` L659 (`init_byte32 = {5'b0, k_q}`). | **CONFIRMED** |
| **Matrix Indexing $\text{XOF}(\rho, j, i)$** | FIPS 203 Alg 13 Step 6: $\text{SampleNTT}(\text{XOF}(\rho, j, i))$ | Sec 2.6.1 (L368), Eq (23) | Exact match to final FIPS 203 (avoids draft transposition error). Verified in RTL. | **CONFIRMED** |
| **Implicit Rejection Key $K_{reject}$** | FIPS 203 Alg 18 Step 9: $\bar{K} \leftarrow J(z \parallel c)$ | Sec 2.6.4 (L482, L551), Eq (48) | Exact match: $J(z \parallel c) = \text{SHAKE256}(z \parallel c, 32)$. Verified in RTL `mlkem_decap_datapath.svh`. | **CONFIRMED** |
| **Resource Budget: 0 BRAM** | the proposed accelerator Microarchitecture: strictly zero Block RAM | Sec 1.0 (L10), Sec 1.4 (L98) | Verified. All RTL storage arrays instantiate `(* ram_style = "distributed" *)`. 0 BRAMs. | **CONFIRMED** |
| **Resource Budget: 8 DSP** | the proposed accelerator Microarchitecture: strictly 8 DSP48E2 slices | Sec 1.0 (L10), Sec 1.4 (L101) | Verified. Exactly 8 `mlkem_dsp_mul` instances in `mlkem_mul_stream.sv`; NTT uses 0 DSPs. | **CONFIRMED** |

---

## 3. Section-by-Section Verification Findings

### 3.1 Title, Abstract, and Author Metadata (Lines 1–15)
- **Title Accuracy:** *"A 413.7 MHz Zero-BRAM 8-DSP All-Security-Level Hardware Accelerator for NIST FIPS 203 (ML-KEM) Post-Quantum Cryptography"*  
  - Accurately captures all key contributions and physical operational boundaries.
- **Abstract Metrics Check:**
  - Operating Frequency: $413.7\text{ MHz}$ ($T_{clk} = 2.417\text{ ns}$). Verified.
  - Resource Consumption: 29,063 LUTs (14.3%), 17,666 FFs (4.35%), 8 DSPs (0.47%), 0 BRAMs (0.0%). Verified against post-routing report on AMD Kintex UltraScale `xcku035-ffva1156-3-e`.
  - Latency Profiles:
    - KeyGen: 1,369 cycles ($3.31\ \mu\text{s}$), 2,104 cycles ($5.09\ \mu\text{s}$), 3,032 cycles ($7.33\ \mu\text{s}$). Verified.
    - Encapsulation: 1,665 cycles ($4.02\ \mu\text{s}$), 2,411 cycles ($5.83\ \mu\text{s}$), 3,412 cycles ($8.25\ \mu\text{s}$). Verified.
    - Decapsulation: 2,497 cycles ($6.04\ \mu\text{s}$), 3,287 cycles ($7.95\ \mu\text{s}$), 4,358 cycles ($10.53\ \mu\text{s}$). Verified.
  - **Identified Terminology Inaccuracy (Line 10):**
    - Current text: *"Fabricated and verified on an AMD Kintex UltraScale FPGA..."*
    - Issue: FPGAs are not "fabricated" by hardware designers; they are synthesized and implemented on off-the-shelf programmable silicon. Fabrication is strictly an ASIC foundry process.
    - Proposed Correction: Change to *"Implemented and verified on an AMD Kintex UltraScale FPGA..."* or *"Synthesized, placed, routed, and verified on an AMD Kintex UltraScale FPGA..."*.

---

### 3.2 Section I: Introduction (Lines 16–130)

#### 1.1 The Post-Quantum Transition and NIST FIPS 203 (Lines 18–44)
- **Historical & Cryptographic Foundation:**
  - Shor's algorithm (1994) polynomial time complexity $\mathcal{O}((\log N)^3)$ against RSA and discrete logs is historically and mathematically accurate.
  - Harvest Now, Decrypt Later (HNDL) paradigm correctly formulated.
- **NIST Timeline & Milestones:**
  - 2016 Call for Proposals, 82 submissions (Round 1 in 2017), 26 Round 2 (2019), Round 3 finalists (2020), July 5, 2022 announcement, and August 13, 2024 formal promulgation of FIPS 203, FIPS 204, and FIPS 205.
  - All standard names (ML-KEM from CRYSTALS-Kyber, ML-DSA from CRYSTALS-Dilithium, SLH-DSA from SPHINCS+) are 100% verified against official NIST records.

#### 1.2 Computational Bottlenecks in Post-Quantum Lattice Cryptography (Lines 45–76)
- **Identified Numerical Inconsistency (Line 46):**
  - Current text: *"imposing extreme hardware and arithmetic overheads across four primary operational domains:"*
  - Problem: The text subsequently enumerates **five** numbered operational domains:
    1. Polynomial Ring Arithmetic and NTT
    2. Cryptographic Sponge Permutations (Keccak-$f[1600]$)
    3. Rejection and Centered Binomial Distribution Sampling
    4. Polynomial Compression, Decompression, and Serialization
    5. Timing Side-Channel Vulnerabilities and Fujisaki-Okamoto Transform
    Furthermore, the summary box (lines 66–74) lists all 5 domains.
  - Proposed Correction: Replace *"four primary operational domains:"* with *"five primary operational domains:"*.
- **Domain Breakdown Checks:**
  - Polynomial arithmetic and NTT: Latency proportion claim (up to 35%) is substantiated by literature benchmarks.
  - Keccak-$f[1600]$: Sponge usage ($H$ = SHA3-256, $G$ = SHA3-512, $\text{XOF}$ = SHAKE-128, $\text{PRF}/J$ = SHAKE-256) conforms to FIPS 203 Section 2.5. Number of Keccak permutations per operation (10–28) matches ML-KEM-512 through ML-KEM-1024.
  - Rejection and CBD Sampling: 168-byte SHAKE-128 squeeze block size ($r = 1344$ bits = 168 bytes) is exact. Rejection rate $(4096 - 3329)/4096 = 767/4096 \approx 18.725\% \approx 18.8\%$ is mathematically exact.
  - Compression codecs: Formula in Line 59 is exact.
    - *Clarification Note (Line 60):* The text notes *"Ciphertext vectors $\mathbf{u}$ and polynomial $v$ are compressed by discarding low-order bits through non-power-of-two modular divisions: ... for $d \in \{1, 4, 5, 10, 11\}$."* While $d_u \in \{10, 11\}$ and $d_v \in \{4, 5\}$ compress ciphertexts $\mathbf{u}$ and $v$, $d = 1$ is used during decryption to decode the recovered message $m \leftarrow \text{ByteEncode}_1(\text{Compress}_1(w))$. Clarifying this distinguishes ciphertext compression from plaintext recovery.

#### 1.3 State-of-the-Art Limitations and Critical Hardware Challenges (Lines 77–92)
- 1.3.1 (BRAM congestion): Accurately contrasts column-bound BRAM routing delays at $>300\text{ MHz}$ against distributed CLB architectures.
- 1.3.2 (DSP consumption): Accurately outlines the resource competition between cryptographic accelerators and co-located edge DSP workloads.
- 1.3.3 (Multi-level agility): Accurately critiques datapath replication vs. unified parameterized scheduling.

#### 1.4 Technical Contributions of this Work (Lines 93–120)
- Verified all 7 itemized contributions against the RTL:
  1. Zero-BRAM: Distributed LUTRAM, SRLs, CLB registers. Confirmed.
  2. Strictly 8-DSP Karatsuba: 2 channels $\times$ 4 DSPs = 8 DSP48E2. Confirmed.
  3. Zero-DSP NTT: Soft Barrett reduction, 4 butterflies, 8 coeffs/cc. Confirmed.
  4. 24-cycle Keccak-$f[1600]$: Single-cycle round datapath, 64-bit absorb. Confirmed.
  5. Division-Free CSD Compression: $161271 \approx 2^{29}/3329$ constant decomposition. Confirmed.
  6. Constant-time FO transform: Lockstep compare, implicit rejection MUX. Confirmed.
  7. Verification: Post-routing metrics at 413.7 MHz on Kintex UltraScale. Confirmed.

---

### 3.3 Section II: Preliminaries and FIPS 203 Mathematical Formulation (Lines 131–555)

#### 2.1 Theoretical Framework and Module-LWE (Lines 135–149)
- Base rings $\mathcal{R} = \mathbb{Z}[X]/(X^{256} + 1)$ and $\mathcal{R}_q = \mathbb{Z}_q[X]/(X^{256} + 1)$ are rigorously stated.
- Module-LWE equation $\mathbf{t} = \mathbf{A}\mathbf{s} + \mathbf{e}$ over $\mathcal{R}_q^k$ with $\mathbf{s} \leftarrow \chi_s^k$ and $\mathbf{e} \leftarrow \chi_e^k$ is mathematically orthodox.
- Lattice dimension $N = n \cdot k = 256k$ confirmed.

#### 2.2 Algebraic Ring Structure and Number Theoretic Transform (Lines 150–193)
- Modulus $q = 3329 = 13 \times 2^8 + 1$: Correctly demonstrates that $256 \mid (q - 1)$ but $512 \nmid (q - 1)$, establishing that $X^{256} + 1$ factors into 128 quadratic polynomials rather than 256 linear polynomials.
- Primitive root $\zeta = 17$: Verified $17^{256} \equiv 1 \pmod{3329}$ and $17^{128} \equiv -1 \pmod{3329}$.
- Ring factorization Eq (6):
  $$X^{256} + 1 \equiv \prod_{i=0}^{127} \left( X^2 - \zeta^{2\cdot\text{BitRev}_7(i) + 1} \right) \pmod{3329}$$
  Matches FIPS 203 Section 2.4 Equation (2.8).
- Dyadic base multiplication Eq (14):
  $$\begin{cases} c_0 = a_0 b_0 + a_1 b_1 \gamma \pmod{3329} \\ c_1 = a_0 b_1 + a_1 b_0 \pmod{3329} \end{cases}$$
  where $\gamma = \zeta^{2\cdot\text{BitRev}_7(i) + 1}$. Matches FIPS 203 Algorithm 11/12.
- Karatsuba formulation Eq (15):
  $$a_0 b_1 + a_1 b_0 = (a_0 + a_1)(b_0 + b_1) - a_0 b_0 - a_1 b_1$$
  Mathematically exact identity.

#### 2.3 Mathematical Notation and Operational Symbols — Table I (Lines 194–233)
Table I provides a thorough mathematical reference. However, a comprehensive audit against the finalized FIPS 203 text reveals several legacy reference discrepancies originating from earlier CRYSTALS-Kyber drafts:

| Symbol / Row in Table I | Table I Current Text | FIPS 203 Standard Definition | Identified Discrepancy & Required Correction |
| :--- | :--- | :--- | :--- |
| $\hat{\mathbf{A}} \circ \hat{\mathbf{s}}$ | Ref: `Algorithm 16` | Performed in `K-PKE.KeyGen` (FIPS 203 Algorithm 13) | **Discrepancy:** In FIPS 203, Algorithm 16 is `ML-KEM.KeyGen_internal(d, z)`. The matrix-vector dyadic product is computed in `K-PKE.KeyGen` (Algorithm 13, Step 11) and `K-PKE.Encrypt` (Algorithm 14, Step 15). **Correction:** Update reference to `Algorithm 13 / 14` or `Section 2.4`. |
| $\mathbb{B}, \mathbb{B}^L$ | Ref: `Section 2.2` | Byte arrays defined in FIPS 203 Section 2.3 | **Minor Discrepancy:** Section 2.2 is general notation; Section 2.3 is explicitly titled *"Bit and Byte Arrays"*. **Correction:** Update reference to `Section 2.3`. |
| $\text{ByteEncode}_d$ | Ref: `Algorithm 3` | In FIPS 203, `ByteEncode_d` is Algorithm 5 | **Discrepancy:** NIST inserted `BitsToBytes` (Alg 3) and `BytesToBits` (Alg 4), shifting `ByteEncode_d` to Algorithm 5. **Correction:** Update reference to `Algorithm 5 (Section 4.2)`. |
| $\text{ByteDecode}_d$ | Ref: `Algorithm 4` | In FIPS 203, `ByteDecode_d` is Algorithm 6 | **Discrepancy:** Shifted in FIPS 203 to Algorithm 6. **Correction:** Update reference to `Algorithm 6 (Section 4.2)`. |
| $\text{SampleNTT}$ | Ref: `Algorithm 5` | In FIPS 203, `SampleNTT` is Algorithm 7 | **Discrepancy:** Shifted in FIPS 203 to Algorithm 7. **Correction:** Update reference to `Algorithm 7 (Section 4.3)`. |
| $\text{SamplePolyCBD}_\eta$ | Ref: `Algorithm 6` | In FIPS 203, `SamplePolyCBD_eta` is Algorithm 8 | **Discrepancy:** Shifted in FIPS 203 to Algorithm 8. **Correction:** Update reference to `Algorithm 8 (Section 4.3)`. |
| $G, H, J, \text{PRF}_\eta, \text{XOF}$ | Ref: `Table 2` | Defined in FIPS 203 Section 2.5 | **Discrepancy:** In FIPS 203, Table 2 specifies key, ciphertext, and shared secret lengths. Symmetric primitives are formally defined in Section 2.5. **Correction:** Update reference to `Section 2.5`. |

#### 2.4 Cryptographic Parameter Sets and Security Categories — Table II (Lines 234–264)
- All numerical values across ML-KEM-512, ML-KEM-768, and ML-KEM-1024 are **100% compliant** with FIPS 203 Tables 1 and 2:
  - Security Categories: 1, 3, 5.
  - Module Rank $k$: 2, 3, 4.
  - Polynomial Degree $n$: 256.
  - Prime Modulus $q$: 3329.
  - $\eta_1$: 3, 2, 2.
  - $\eta_2$: 2, 2, 2.
  - $d_u$: 10, 10, 11.
  - $d_v$: 4, 4, 5.
  - $ek$ byte length: $384k + 32 \implies 800, 1184, 1568$ Bytes.
  - $dk$ byte length: $768k + 96 \implies 1632, 2400, 3168$ Bytes.
  - $c$ byte length: $32(k\cdot d_u + d_v) \implies 768, 1088, 1568$ Bytes.
    - $c_1 = 32 \cdot k \cdot d_u \implies 640, 960, 1408$ Bytes.
    - $c_2 = 32 \cdot d_v \implies 128, 128, 160$ Bytes.
  - Shared secret $K$: 32 Bytes (256 bits).
  - Decapsulation failure probability $\delta$: $2^{-139}, 2^{-164}, 2^{-174}$.
- **Terminology Polish (Line 256):**
  - Table II row 17 labels this: `**Decryption Failure Probability**`.
  - While technically describing the underlying K-PKE decryption failure rate, FIPS 203 Table 1 explicitly designates this as the *decapsulation failure probability* of ML-KEM. Adopting `**Decapsulation Failure Probability**` or `**Decapsulation Failure Probability ($\delta$)**` achieves perfect standards alignment.

#### 2.5 Fundamental Auxiliary Building Blocks (Lines 265–334)
- **2.5.1 Coefficient Compression and Decompression:**
  - $\text{Compress}_d(x) = \lfloor (2^d \cdot x + \lfloor q/2 \rfloor) / q \rfloor \pmod{2^d} = \lfloor (2^d \cdot x + 1664) / 3329 \rfloor \bmod 2^d$ (Eq 16). Correct.
  - $\text{Decompress}_d(y) = \lfloor (q \cdot y + 2^{d-1}) / 2^d \rfloor$ (Eq 17). Correct.
  - Rounding error bound $|x' - x \bmod^{\pm} q| \le \lfloor q / 2^{d+1} \rceil$ (Eq 18). Correct.
- **2.5.2 Byte Encoding and Decoding:**
  - Packing formulas for $d = 12$ in Eq (19) and unpacking formulas in Eq (20) match FIPS 203 Algorithms 5 and 6.
- **2.5.3 Uniform Rejection Sampling ($\text{SampleNTT}$, Lines 287–313):**
  - Algorithm pseudo-code in Algorithm 1 is mathematically and logically identical to FIPS 203.
  - **Discrepancy (Line 290):** Heading reads `Algorithm 1: SampleNTT(B) (FIPS 203 Algorithm 5)`.
    - In FIPS 203, `SampleNTT` is **Algorithm 7**.
    - Correction: Update to `Algorithm 1: SampleNTT(B) (FIPS 203 Algorithm 7)`.
  - Rejection rate: Acceptance is $3329/4096 \approx 81.28\%$; rejection rate is $18.72\%$. Accurately stated.
- **2.5.4 Centered Binomial Distribution Sampling ($\text{SamplePolyCBD}_\eta$, Lines 314–334):**
  - Algorithm pseudo-code in Algorithm 2 is mathematically and logically identical to FIPS 203.
  - **Discrepancy (Line 318):** Heading reads `Algorithm 2: SamplePolyCBD_eta(B) (FIPS 203 Algorithm 6)`.
    - In FIPS 203, `SamplePolyCBD_eta` is **Algorithm 8**.
    - Correction: Update to `Algorithm 2: SamplePolyCBD_eta(B) (FIPS 203 Algorithm 8)`.
  - Statistical properties: $\mathbb{E}[f_i] = 0$, $\text{Var}(f_i) = \eta / 2$. Confirmed ($\text{Var} = 1.0$ for $\eta=2$; $\text{Var} = 1.5$ for $\eta=3$).

#### 2.6 Complete Cryptographic Workflows of FIPS 203 (Lines 335–555)
- **Hierarchy Diagram (Lines 340–359):** Correctly delineates the relationship between K-PKE and ML-KEM via the Fujisaki-Okamoto transform.
- **2.6.1 K-PKE Primitive Verification:**
  - **K-PKE.KeyGen (Algorithm 13):**
    - Step 1: $(\rho, \sigma) \leftarrow G(d \parallel k) = \text{SHA3-512}(d \parallel k)$ (Eq 22). Perfectly captures the FIPS 203 domain separation enhancement. Verified in RTL `mlkem_hash_sampler.sv`.
    - Step 2: $\hat{\mathbf{A}}[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, j, i))$ (Eq 23). Verified in RTL.
    - Step 3: $\mathbf{s}[i], \mathbf{e}[i] \leftarrow \text{SamplePolyCBD}_{\eta_1}(\text{PRF}(\sigma, N))$.
      - *Minor formatting note:* In FIPS 203 Algorithm 13, $N$ is initialized to 0 ($N \leftarrow 0$) and incremented. The notation $\text{PRF}_{\eta_1}(\sigma, N)$ explicitly indicates output length $64\eta_1$ bytes.
    - Steps 4–6: $\hat{\mathbf{s}}, \hat{\mathbf{e}}$ transforms, $\hat{\mathbf{t}} \leftarrow \hat{\mathbf{A}} \circ \hat{\mathbf{s}} + \hat{\mathbf{e}}$, serialization into $ek_{PKE}$ and $dk_{PKE}$. 100% verified.
  - **K-PKE.Encrypt (Algorithm 14):**
    - Step 1: Unpacking $ek_{PKE}$ into $\hat{\mathbf{t}}$ and $\rho$. Correct.
    - Step 2: $\hat{\mathbf{A}}^T[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, i, j))$ (Eq 31). Correct.
    - Step 3: Noise sampling $\mathbf{r}, \mathbf{e}_1, e_2$. Correct.
    - Step 4: $\hat{\mathbf{r}} \leftarrow \text{NTT}(\mathbf{r})$. Correct.
    - Step 5: Ciphertext vector and scalar arithmetic:
      $$\mathbf{u} \leftarrow \text{INTT}(\hat{\mathbf{A}}^T \circ \hat{\mathbf{r}}) + \mathbf{e}_1 \in \mathcal{R}_q^k \tag{36}$$
      $$v \leftarrow \text{INTT}(\hat{\mathbf{t}}^T \circ \hat{\mathbf{r}}) + e_2 + \text{Decompress}_1(\text{ByteDecode}_1(m)) \in \mathcal{R}_q \tag{37}$$
      Both equations match FIPS 203 Algorithm 14 Steps 18–20.
    - Step 6: Compression and byte-packing $c_1 \parallel c_2$. Correct.
  - **K-PKE.Decrypt (Algorithm 15):**
    - Step 1: Decompress $\mathbf{u}$ and $v$. Correct.
    - Step 2: Unpack $\hat{\mathbf{s}}$. Correct.
    - Step 3: Recover message:
      $$w \leftarrow v - \text{INTT}(\hat{\mathbf{s}}^T \circ \text{NTT}(\mathbf{u})) \in \mathcal{R}_q \tag{44}$$
      $$m \leftarrow \text{ByteEncode}_1(\text{Compress}_1(w)) \in \mathbb{B}^{32} \tag{45}$$
      Matches FIPS 203 Algorithm 15 Steps 3–4.
- **2.6.2 ML-KEM.KeyGen (Algorithm 16 & 19):**
  - Algorithm 3 (`ML-KEM.KeyGen_internal`): Verified against FIPS 203 Algorithm 16.
  - Decapsulation key structure Eq (46): $dk = \text{ByteEncode}_{12}(\hat{\mathbf{s}}) \parallel ek \parallel H(ek) \parallel z$ ($768k + 96$ bytes). Exact match.
- **2.6.3 ML-KEM.Encaps (Algorithm 17 & 20):**
  - Algorithm 4 (`ML-KEM.Encaps_internal`):
    - Key validation check (Lines 444–447):
      `if ByteEncode_12(ByteDecode_12(ek[0 : 384*k])) != ek[0 : 384*k] then return error`
      Verified. In FIPS 203, this check is formally located in Algorithm 20 (`ML-KEM.Encaps(ek)`), while Algorithm 17 (`ML-KEM.Encaps_internal`) receives a validated key. In the proposed accelerator's hardware datapath, this validation is performed directly on the ingress streaming interface. Adding a brief parenthetical note on this architectural consolidation improves clarity.
    - Return tuple ordering (Line 451): `return (c, K)`. Note that FIPS 203 specifies output ordering $(K, c)$. Both forms are common, but aligning with $(K, c)$ strictly adheres to the standard.
- **2.6.4 ML-KEM.Decaps & Fujisaki-Okamoto Transform (Algorithm 18 & 21):**
  - Key parsing offsets (Lines 470–473): $dk_{PKE} = dk[0 : 384k]$, $ek = dk[384k : 768k + 32]$, $h = dk[768k + 32 : 768k + 64]$, $z = dk[768k + 64 : 768k + 96]$. Exact match.
  - Step 1: $m' \leftarrow \text{K-PKE.Decrypt}(dk_{PKE}, c)$. Correct.
  - Step 2: $(K', r') \leftarrow G(m' \parallel h)$. Correct.
  - Step 3: $K_{reject} \leftarrow J(z \parallel c) = \text{SHAKE256}(z \parallel c, 32)$. Matches FIPS 203 Algorithm 18 Step 9 ($\bar{K} \leftarrow J(z \parallel c)$). Verified in RTL `mlkem_decap_datapath.svh`.
  - Step 4: Re-encryption $c' \leftarrow \text{K-PKE.Encrypt}(ek, m', r')$. Correct.
  - Step 5: Constant-time conditional return (if $c' == c$ then return $K'$ else return $K_{reject}$). Correct. Verified in RTL `mlkem_encap_datapath.svh` L28–29 (`shared_secret = dec_mismatch ? dec_reject : enc_secret_q`).
  - Diagram (Lines 496–543): ASCII datapath diagram accurately traces ciphertext, secret keys, hash functions, and constant-time MUX.
  - Cryptographic rationale for implicit rejection (Lines 545–554): Detailed, rigorous explanation of defeating CCA2 decryption failure oracle attacks in QROM.

---

## 4. Comprehensive List of Confirmed Claims (Ground Truth Verified)

1. **Modulus & Ring Arithmetic:** Modulus $q = 3329 = 13 \times 2^8 + 1$, primitive root $\zeta = 17$, degree $n = 256$, cyclotomic polynomial $X^{256} + 1$, and its incomplete splitting into 128 quadratic factors modulo $(X^2 - \zeta^{2\cdot\text{BitRev}_7(i)+1})$ are verified against FIPS 203 Section 2.4 and the RTL implementation.
2. **Dyadic Base Multiplication & Karatsuba:** Dyadic multiplication formulas for $c_0, c_1$ modulo $(X^2 - \gamma)$ and the 3-multiplication Karatsuba decomposition of $(a_0 b_1 + a_1 b_0)$ are verified against FIPS 203 Algorithm 11/12 and RTL `mlkem_mul_stream.sv`.
3. **All Parameter Configurations in Table II:** Security categories (1, 3, 5), ranks $k \in \{2, 3, 4\}$, noise widths $\eta_1 \in \{3, 2, 2\}$, $\eta_2 = 2$, compression depths $d_u \in \{10, 10, 11\}$, $d_v \in \{4, 4, 5\}$, key lengths ($ek$: 800, 1184, 1568 B; $dk$: 1632, 2400, 3168 B), ciphertext lengths (768, 1088, 1568 B), shared secret length (32 B), and decapsulation failure rates ($2^{-139}, 2^{-164}, 2^{-174}$) are verified against FIPS 203 Tables 1 and 2 and RTL testbenches.
4. **FIPS 203 Domain Separation in Seed Expansion:** Equation (22) correctly implements $(\rho, \sigma) \leftarrow G(d \parallel k)$ with $k$ appended as a single byte, verified against FIPS 203 Algorithm 13 Step 1 and RTL `mlkem_hash_sampler.sv` lines 658–660.
5. **FIPS 203 Public Matrix Expansion Indexing:** Equation (23) correctly implements $\hat{\mathbf{A}}[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, j, i))$ in KeyGen, and Equation (31) implements $\hat{\mathbf{A}}^T[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, i, j))$ in Encrypt, verified against FIPS 203 Algorithm 13/14 and RTL `mlkem_hash_sampler.sv` lines 663–667.
6. **Fujisaki-Okamoto Transform with Implicit Rejection:** Decapsulation re-encryption and fallback key generation $K_{reject} \leftarrow J(z \parallel c) = \text{SHAKE256}(z \parallel c, 32)$ are verified against FIPS 203 Algorithm 18 and RTL `mlkem_decap_datapath.svh` and `mlkem_encap_datapath.svh`.
7. **Strictly Zero-BRAM Storage Architecture:** All internal storage buffers in `mlkem_keygen_top.sv` (`ram_s_b0..3`, `ram_e`, `ram_pk_b0..3`, `ram_t`) and `mlkem_encap_datapath.svh` (`enc_product_ram_b0..4`) explicitly use `(* ram_style = "distributed" *)`, guaranteeing 0 BRAM36/18 consumption.
8. **Strictly Eight-DSP Multiplier:** Pointwise streaming multiplier `mlkem_mul_stream.sv` instantiates exactly 8 `mlkem_dsp_mul` primitives (4 DSPs per channel $\times$ 2 channels); `mlkem_butterfly.sv` explicitly enforces `(* use_dsp = "no" *)`.
9. **24-Cycle Keccak-$f[1600]$ Engine:** `keccak_f1600.sv` operates with `FAST_24 = 1`, achieving 1 round per cycle (24 clock cycles total per permutation).
10. **Division-Free CSD Compression:** `mlkem_poly_compress.sv` converts division by 3329 into fixed-point multiplication using $161271 \approx 2^{29}/3329$ via an adder tree ($T = 5x, U = 9x, V = 512T + U, \text{prod} = 32768T - V = 161271x$).
11. **Operating Frequency & Verification:** Physical synthesis, placement, and routing on AMD Kintex UltraScale `xcku035-ffva1156-3-e` confirms $F_{max} = 413.7\text{ MHz}$ ($T_{clk} = 2.417\text{ ns}$) with 29,063 LUTs, 17,666 registers, 8 DSPs, and 0 BRAMs.

---

## 5. Identified Discrepancies, Ambiguities, and Required Corrections

This section documents all discrepancies, citation drifts, and ambiguities identified in `paper/sections/sec01_02_intro_prelims.md` (and lines 1–555 of `paper/mlkem_the proposed accelerator_ieee_paper.md`), accompanied by exact line numbers and proposed drop-in replacements.

---

### Finding 1: Academic Terminology Polish in Abstract
- **Location:** Line 10 (Abstract).
- **Target Text:**
  ```markdown
  Fabricated and verified on an AMD Kintex UltraScale FPGA, the proposed accelerator operates at 413.7 MHz while consuming only 29,063 LUTs, 17,666 registers, 8 DSPs, and 0 BRAMs.
  ```
- **Issue:** The word *"Fabricated"* is incorrect for an FPGA design. FPGAs are commercial off-the-shelf programmable chips; hardware accelerators targeting FPGAs are synthesized, placed, routed, and implemented.
- **Proposed Replacement:**
  ```markdown
  Implemented and verified on an AMD Kintex UltraScale FPGA, the proposed accelerator operates at 413.7 MHz while consuming only 29,063 LUTs, 17,666 registers, 8 DSPs, and 0 BRAMs.
  ```

---

### Finding 2: Enumeration Count Inconsistency in Section 1.2
- **Location:** Line 46.
- **Target Text:**
  ```markdown
  imposing extreme hardware and arithmetic overheads across four primary operational domains:
  ```
- **Issue:** The text states *"four primary operational domains:"*, but then enumerates **five** numbered operational domains (1. Polynomial Ring Arithmetic / NTT, 2. Keccak-$f[1600]$, 3. Rejection / CBD Sampling, 4. Polynomial Compression Codecs, 5. Timing Side-Channels / FO Transform).
- **Proposed Replacement:**
  ```markdown
  imposing extreme hardware and arithmetic overheads across five primary operational domains:
  ```

---

### Finding 3: Functional Scope Clarification for $d=1$ Compression in Section 1.2
- **Location:** Lines 58–60.
- **Target Text:**
  ```markdown
  4. **Polynomial Compression, Decompression, and Serialization:**
     Ciphertext vectors $\mathbf{u}$ and polynomial $v$ are compressed by discarding low-order bits through non-power-of-two modular divisions:
     $$\text{Compress}_d(x) = \left\lfloor \frac{2^d \cdot x + \lfloor q/2 \rfloor}{q} \right\rfloor \pmod{2^d}$$
     for $d \in \{1, 4, 5, 10, 11\}$. Direct hardware implementation of division by $q = 3329$ consumes extensive logic and latency, while bit-packing arbitrary bit-widths into byte streams introduces unaligned boundary crossings that stall pipeline flows.
  ```
- **Issue:** In ML-KEM, ciphertext components are compressed using $d_u \in \{10, 11\}$ and $d_v \in \{4, 5\}$; $d = 1$ is used specifically during decryption to decode the recovered message $m \leftarrow \text{ByteEncode}_1(\text{Compress}_1(w))$. Grouping $d = 1$ under "Ciphertext vectors $\mathbf{u}$ and polynomial $v$ are compressed" is technically imprecise.
- **Proposed Replacement:**
  ```markdown
  4. **Polynomial Compression, Decompression, and Serialization:**
     Ciphertext vectors $\mathbf{u}$ and polynomial $v$ are compressed by discarding low-order bits through non-power-of-two modular divisions ($d_u \in \{10, 11\}$, $d_v \in \{4, 5\}$), while message recovery in decryption evaluates $d = 1$:
     $$\text{Compress}_d(x) = \left\lfloor \frac{2^d \cdot x + \lfloor q/2 \rfloor}{q} \right\rfloor \pmod{2^d}$$
     for $d \in \{1, 4, 5, 10, 11\}$. Direct hardware implementation of division by $q = 3329$ consumes extensive logic and latency, while bit-packing arbitrary bit-widths into byte streams introduces unaligned boundary crossings that stall pipeline flows.
  ```

---

### Finding 4: Standard Algorithm Reference Drift in Table I
- **Location:** Lines 211, 212–213, 222–225, 226–230 (Table I).
- **Target Text (Table I entries):**
  ```markdown
  | $\hat{\mathbf{A}} \circ \hat{\mathbf{s}}$ | $\mathcal{T}_q^{k \times k} \times \mathcal{T}_q^k \to \mathcal{T}_q^k$ | Matrix-vector multiplication using dyadic base products. | Algorithm 16 |
  | $\mathbb{B}$ | $\{0, 1, \dots, 255\}$ | Finite set of 8-bit bytes ($\{0, 1\}^8$). | Section 2.2 |
  | $\mathbb{B}^L$ | Byte array | Array of $L$ bytes, indexed as $B[0], B[1], \dots, B[L-1]$. | Section 2.2 |
  ...
  | $\text{ByteEncode}_d$| $\mathbb{Z}_{2^d}^{256} \to \mathbb{B}^{32d}$ | Bit-packing 256 $d$-bit coefficients into a contiguous byte stream. | Algorithm 3 |
  | $\text{ByteDecode}_d$| $\mathbb{B}^{32d} \to \mathbb{Z}_{2^d}^{256}$ | Unpacking contiguous byte stream into 256 $d$-bit coefficients. | Algorithm 4 |
  | $\text{SampleNTT}$ | $\mathbb{B}^* \to \mathcal{T}_q$ | Uniform rejection sampling from SHAKE-128 squeeze stream. | Algorithm 5 |
  | $\text{SamplePolyCBD}_\eta$| $\mathbb{B}^{64\eta} \to \mathcal{R}_q$ | Centered Binomial Distribution sampling from SHAKE-256 stream. | Algorithm 6 |
  | $G$ | $\mathbb{B}^* \to \mathbb{B}^{64}$ | Cryptographic hash function SHA3-512. | Table 2 |
  | $H$ | $\mathbb{B}^* \to \mathbb{B}^{32}$ | Cryptographic hash function SHA3-256. | Table 2 |
  | $J$ | $\mathbb{B}^* \to \mathbb{B}^{32}$ | Extendable output function SHAKE-256 (32-byte squeeze). | Table 2 |
  | $\text{PRF}_\eta(s, b)$ | $\mathbb{B}^{32} \times \mathbb{B} \to \mathbb{B}^{64\eta}$ | Pseudorandom function: $\text{SHAKE256}(s \parallel b, 64\eta)$. | Table 2 |
  | $\text{XOF}(\rho, i, j)$ | $\mathbb{B}^{32} \times \mathbb{B} \times \mathbb{B} \to \mathbb{B}^*$ | Extendable-output function: $\text{SHAKE128}(\rho \parallel i \parallel j)$. | Table 2 |
  ```
- **Issue:**
  1. $\hat{\mathbf{A}} \circ \hat{\mathbf{s}}$ cites `Algorithm 16`. In FIPS 203, Algorithm 16 is `ML-KEM.KeyGen_internal`. Matrix multiplication is performed in `K-PKE.KeyGen` (**Algorithm 13**).
  2. $\mathbb{B}$ and $\mathbb{B}^L$ cite `Section 2.2`. In FIPS 203, Section 2.2 is general notation; Section 2.3 is explicitly *"Bit and Byte Arrays"*.
  3. $\text{ByteEncode}_d$ cites `Algorithm 3`, $\text{ByteDecode}_d$ cites `Algorithm 4`, $\text{SampleNTT}$ cites `Algorithm 5`, and $\text{SamplePolyCBD}_\eta$ cites `Algorithm 6`. In the ratified FIPS 203 standard, these algorithms are **Algorithm 5, Algorithm 6, Algorithm 7, and Algorithm 8**, respectively (due to the insertion of `BitsToBytes` as Alg 3 and `BytesToBits` as Alg 4).
  4. Symmetric primitives $G, H, J, \text{PRF}, \text{XOF}$ cite `Table 2`. In FIPS 203, Table 2 specifies key and ciphertext lengths. The symmetric primitives are specified in **Section 2.5**.
- **Proposed Replacement:**
  ```markdown
  | $\hat{\mathbf{A}} \circ \hat{\mathbf{s}}$ | $\mathcal{T}_q^{k \times k} \times \mathcal{T}_q^k \to \mathcal{T}_q^k$ | Matrix-vector multiplication using dyadic base products. | Algorithm 13 / 14 |
  | $\mathbb{B}$ | $\{0, 1, \dots, 255\}$ | Finite set of 8-bit bytes ($\{0, 1\}^8$). | Section 2.3 |
  | $\mathbb{B}^L$ | Byte array | Array of $L$ bytes, indexed as $B[0], B[1], \dots, B[L-1]$. | Section 2.3 |
  ...
  | $\text{ByteEncode}_d$| $\mathbb{Z}_{2^d}^{256} \to \mathbb{B}^{32d}$ | Bit-packing 256 $d$-bit coefficients into a contiguous byte stream. | Algorithm 5 |
  | $\text{ByteDecode}_d$| $\mathbb{B}^{32d} \to \mathbb{Z}_{2^d}^{256}$ | Unpacking contiguous byte stream into 256 $d$-bit coefficients. | Algorithm 6 |
  | $\text{SampleNTT}$ | $\mathbb{B}^* \to \mathcal{T}_q$ | Uniform rejection sampling from SHAKE-128 squeeze stream. | Algorithm 7 |
  | $\text{SamplePolyCBD}_\eta$| $\mathbb{B}^{64\eta} \to \mathcal{R}_q$ | Centered Binomial Distribution sampling from SHAKE-256 stream. | Algorithm 8 |
  | $G$ | $\mathbb{B}^* \to \mathbb{B}^{64}$ | Cryptographic hash function SHA3-512. | Section 2.5 |
  | $H$ | $\mathbb{B}^* \to \mathbb{B}^{32}$ | Cryptographic hash function SHA3-256. | Section 2.5 |
  | $J$ | $\mathbb{B}^* \to \mathbb{B}^{32}$ | Extendable output function SHAKE-256 (32-byte squeeze). | Section 2.5 |
  | $\text{PRF}_\eta(s, b)$ | $\mathbb{B}^{32} \times \mathbb{B} \to \mathbb{B}^{64\eta}$ | Pseudorandom function: $\text{SHAKE256}(s \parallel b, 64\eta)$. | Section 2.5 |
  | $\text{XOF}(\rho, i, j)$ | $\mathbb{B}^{32} \times \mathbb{B} \times \mathbb{B} \to \mathbb{B}^*$ | Extendable-output function: $\text{SHAKE128}(\rho \parallel i \parallel j)$. | Section 2.5 |
  ```

---

### Finding 5: Table II Row Nomenclature Alignment
- **Location:** Line 256 (Table II).
- **Target Text:**
  ```markdown
  | **Decryption Failure Probability** | $\delta$ | $2^{-139}$ | $2^{-164}$ | $2^{-174}$ |
  ```
- **Issue:** In FIPS 203 Tables 1 and 3, NIST designates this parameter as the *decapsulation failure probability* of ML-KEM.
- **Proposed Replacement:**
  ```markdown
  | **Decapsulation Failure Probability** | $\delta$ | $2^{-139}$ | $2^{-164}$ | $2^{-174}$ |
  ```

---

### Finding 6: Algorithm 1 Heading Citation Update
- **Location:** Line 290.
- **Target Text:**
  ```markdown
  Algorithm 1: SampleNTT(B) (FIPS 203 Algorithm 5)
  ```
- **Issue:** In ratified NIST FIPS 203, `SampleNTT` is **Algorithm 7** (Section 4.3). Algorithm 5 is `ByteEncode_d`.
- **Proposed Replacement:**
  ```markdown
  Algorithm 1: SampleNTT(B) (FIPS 203 Algorithm 7)
  ```

---

### Finding 7: Algorithm 2 Heading Citation Update
- **Location:** Line 318.
- **Target Text:**
  ```markdown
  Algorithm 2: SamplePolyCBD_eta(B) (FIPS 203 Algorithm 6)
  ```
- **Issue:** In ratified NIST FIPS 203, `SamplePolyCBD_eta` is **Algorithm 8** (Section 4.3). Algorithm 6 is `ByteDecode_d`.
- **Proposed Replacement:**
  ```markdown
  Algorithm 2: SamplePolyCBD_eta(B) (FIPS 203 Algorithm 8)
  ```

---

### Finding 8: Key Validation Context in Algorithm 4
- **Location:** Lines 438, 444–447.
- **Target Text:**
  ```markdown
  Algorithm 4: ML-KEM.Encaps_internal(ek, m) (FIPS 203 Algorithm 17)
  ...
  1:  // Key validation: verify ek length and coefficient validity
  2:  if ByteEncode_12(ByteDecode_12(ek[0 : 384*k])) != ek[0 : 384*k] then
  3:      return error
  4:  end if
  ```
- **Observation:** In FIPS 203, the key validation check `ByteEncode_12(ByteDecode_12(...))` is specified in Algorithm 20 (`ML-KEM.Encaps`), which then invokes `ML-KEM.Encaps_internal(ek, m)` (Algorithm 17) with valid inputs. In the proposed accelerator's hardware design, the input validation check is directly embedded into the encapsulation datapath pipeline.
- **Recommendation:** Add an explanatory sentence in the narrative preceding Algorithm 4:
  *"Note: In FIPS 203, encapsulation key validation is formally specified in Algorithm 20; in the proposed accelerator, key validation is executed on-the-fly directly within the encapsulation pipeline as shown in Algorithm 4."*

---

## 6. Audit Summary & Next Steps

The mathematical core, cryptographic specifications, and hardware mappings of Section I and Section II are in **exceptional alignment** with both NIST FIPS 203 and the underlying the proposed accelerator SystemVerilog RTL implementation. All verified parameters, equations, and architectural mechanisms are mathematically sound.

Applying the targeted, precise replacements documented in Section 5 will achieve complete perfection in citations and academic rigor, preparing the manuscript for publication in *IEEE Transactions on VLSI Systems* or *IEEE Transactions on Computers*.
