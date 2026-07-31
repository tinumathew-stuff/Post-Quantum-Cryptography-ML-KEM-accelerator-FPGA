# A 413.7 MHz Zero-BRAM 8-DSP All-Security-Level Hardware Accelerator for NIST FIPS 203 (ML-KEM) Post-Quantum Cryptography

**Authors:** High-Performance Cryptographic Hardware Research Group  
**Affiliation:** Department of Electrical and Computer Engineering & High-Assurance Computing Laboratory  
**Target Publication:** *IEEE Transactions on Very Large Scale Integration (VLSI) Systems* / *IEEE Transactions on Computers*

---

### Abstract
With the formal ratification of NIST FIPS 203 in August 2024, transitioning public-key infrastructures to lattice-based post-quantum cryptography (PQC) has become critical to defend against quantum cryptanalysis enabled by Shor's algorithm. However, existing FPGA and ASIC hardware implementations of the Module-Lattice-Based Key-Encapsulation Mechanism (ML-KEM) suffer from prohibitive Block RAM (BRAM) consumption that induces routing bottlenecks, excessive digital signal processing (DSP) slice usage that restricts deployment on resource-constrained edge platforms, and an inability to dynamically support multiple security levels. This paper presents the proposed accelerator, a unified, high-performance, all-security-level cryptographic accelerator for NIST FIPS 203 supporting ML-KEM-512, ML-KEM-768, and ML-KEM-1024. the proposed accelerator establishes an ultra-constrained physical resource budget featuring: 1) a strictly zero-BRAM storage architecture utilizing distributed CLB LUTRAM, shift registers, and flip-flops; 2) a streaming dual-channel Karatsuba pointwise multiplier restricted to strictly 8 DSP48E2 slices; 3) a 4-butterfly parallel Number Theoretic Transform (NTT) engine achieving 8 coefficients per cycle with strictly 0 DSPs via soft-logic Barrett modular reduction; 4) a 24-cycle Keccak-$f[1600]$ engine with a 64-bit lane absorb interface; 5) division-free Canonical Signed Digit (CSD) compression codecs; and 6) a constant-time Fujisaki-Okamoto transform datapath with implicit rejection. Implemented and verified on an AMD Kintex UltraScale FPGA, the proposed accelerator operates at 413.7 MHz while consuming only 29,063 LUTs, 17,666 registers, 8 DSPs, and 0 BRAMs. Execution latencies are 1,369 / 2,104 / 3,032 cycles (3.31 / 5.09 / 7.33 $\mu$s) for KeyGen, 1,665 / 2,411 / 3,412 cycles (4.02 / 5.83 / 8.25 $\mu$s) for Encapsulation, and 2,497 / 3,287 / 4,358 cycles (6.04 / 7.95 / 10.53 $\mu$s) for Decapsulation across Categories 1, 3, and 5, demonstrating superior area-time-hardware efficiency.

**Index Terms—** Post-Quantum Cryptography (PQC), NIST FIPS 203, Module-Lattice-Based Key-Encapsulation Mechanism (ML-KEM), Hardware Accelerator, Field-Programmable Gate Array (FPGA), Zero-BRAM Architecture, Number Theoretic Transform (NTT), Keccak-$f[1600]$, Fujisaki-Okamoto Transform, Constant-Time Implementation.

---

# Section I: Introduction

## 1.1 The Post-Quantum Transition and NIST FIPS 203
For more than four decades, the security foundations of global telecommunications, electronic commerce, financial settlement networks, and secure distributed computing have rested upon public-key cryptography (PKC). Prominent asymmetric algorithms—most notably RSA, Diffie-Hellman (DH), and Elliptic Curve Cryptography (ECDH and ECDSA)—derive their computational hardness from the intractability of two classical number-theoretic problems: integer factorization and the discrete logarithm problem over finite abelian groups. However, the emergence of quantum computing fundamentally threatens these foundational primitives. As demonstrated by Peter Shor in 1994, a sufficiently large, fault-tolerant quantum computer (FTQC) executing Shor's algorithm can solve both integer factorization and discrete logarithms in polynomial time, $\mathcal{O}((\log N)^3)$, effectively reducing the cryptographic strength of 2048-bit RSA and 256-bit ECC to zero.

The urgency of this vulnerability is drastically amplified by the "Harvest Now, Decrypt Later" (HNDL) adversarial paradigm. Nation-state adversaries and malicious entities are actively intercepting, harvesting, and archiving encrypted sensitive traffic traversing public backbones today. Once an operational FTQC becomes available, archived ciphertexts will be retrospectively decrypted, permanently compromising long-term secrets, sovereign communications, classified defense assets, and personal health records whose confidentiality requirement spans decades.

In response to this existential threat, the National Institute of Standards and Technology (NIST) initiated an international Post-Quantum Cryptography (PQC) Standardization Project in 2016 to solicit, evaluate, and standardize quantum-resistant public-key primitives. Following three rigorous evaluation rounds spanning eight years, NIST announced its primary selections in July 2022 and formally promulgated the initial suite of federal standards on August 13, 2024:
1. **Federal Information Processing Standard (FIPS) 203:** *Module-Lattice-Based Key-Encapsulation Mechanism Standard (ML-KEM)*, derived from the CRYSTALS-Kyber submission;
2. **FIPS 204:** *Module-Lattice-Based Digital Signature Standard (ML-DSA)*, derived from CRYSTALS-Dilithium;
3. **FIPS 205:** *Stateless Hash-Based Digital Signature Standard (SLH-DSA)*, derived from SPHINCS+.

Among these, FIPS 203 (ML-KEM) constitutes the universal standard for quantum-resistant key establishment and public-key encryption across digital communications protocols, including Transport Layer Security (TLS 1.3), Internet Key Exchange (IKEv2), Secure Shell (SSH), and Virtual Private Networks (VPNs).

```
+---------------------------------------------------------------------------------------------------+
| NIST Post-Quantum Cryptography Standardization Timeline & Milestone Transitions                  |
+---------------------------------------------------------------------------------------------------+
|  2016: NIST announces Call for Proposals for Post-Quantum Cryptographic Algorithms               |
|  2017: 82 candidate algorithms submitted (Round 1 begins)                                        |
|  2019: 26 candidates advance to Round 2                                                           |
|  2020: 7 finalists and 8 alternate candidates selected for Round 3                              |
|  2022: NIST selects CRYSTALS-Kyber as primary KEM standard (Announcement July 5, 2022)             |
|  2023: Draft FIPS 203 released for public review and industry feedback                           |
|  2024: Formal Release of FIPS 203 (ML-KEM) on August 13, 2024                                    |
|        - Transition mandate initiates across government, enterprise, and telecommunication links   |
+---------------------------------------------------------------------------------------------------+
```

## 1.2 Computational Bottlenecks in Post-Quantum Lattice Cryptography
While classical algorithms like RSA and ECDH rely on scalar field and group operations, ML-KEM is grounded upon the Module Learning With Errors ($\text{M-LWE}$) problem over structured polynomial rings. The computational profile of ML-KEM departs dramatically from classical asymmetric primitives, imposing extreme hardware and arithmetic overheads across five primary operational domains:

1. **Polynomial Ring Arithmetic and the Number Theoretic Transform (NTT):**
   ML-KEM operates over the cyclotomic quotient ring $\mathcal{R}_q = \mathbb{Z}_q[X] / (X^{256} + 1)$ with prime modulus $q = 3329$. Because polynomial multiplication in the time domain exhibits quadratic complexity $\mathcal{O}(n^2)$, high-performance implementations transform polynomials into the NTT domain using the discrete Fourier-like ring isomorphism. However, because $q - 1 = 3328 = 13 \times 2^8$, the ring $\mathcal{R}_q$ does not split completely into linear factors over $\mathbb{Z}_q$, but instead into 128 quadratic polynomial factors modulo $(X^2 - \zeta^{2\cdot\text{BitRev}_7(i) + 1})$. This incomplete splitting requires degree-1 dyadic base multiplications $\hat{f} \circ \hat{g}$, interleaved modular butterfly reductions, and complex twiddle-factor address generators. The high volume of polynomial ring transformations ($\text{NTT}$ and $\text{INTT}$) performed per key encapsulation and decapsulation cycle constitutes up to 35% of the total algorithmic latency.

2. **Cryptographic Sponge Permutations (Keccak-$f[1600]$):**
   ML-KEM makes ubiquitous use of the Keccak sponge construction across multiple NIST FIPS 202 instantiations: SHA3-256 for public-key hashing ($H$), SHA3-512 for pseudorandom seed expansion ($G$), SHAKE-128 for matrix coefficient generation ($\text{XOF}$), and SHAKE-256 for noise polynomial derivation ($\text{PRF}$) and rejection key generation ($J$). A complete encapsulation or decapsulation execution demands between 10 and 28 separate 24-round Keccak-$f[1600]$ state permutations. In software running on general-purpose processors, Keccak permutations dominate total execution time, consuming up to 60% of all clock cycles.

3. **Rejection and Centered Binomial Distribution Sampling:**
   The generation of public matrix $\hat{\mathbf{A}} \in \mathcal{R}_q^{k \times k}$ requires parsing uniform 168-byte SHAKE-128 squeeze blocks through a 12-bit rejection filter ($\text{SampleNTT}$). Coefficients $d \ge 3329$ are rejected, resulting in a non-deterministic throughput pattern with a rejection rate of $\approx 18.8\%$. Concurrently, noise vectors $\mathbf{s}, \mathbf{e}, \mathbf{r}, \mathbf{e}_1, e_2$ are generated by sampling from the Centered Binomial Distribution ($\text{SamplePolyCBD}_\eta$) with parameter $\eta \in \{2, 3\}$. Rejection stalls, multi-word byte-to-coefficient re-alignment, and lane buffering introduce severe throughput throttles in conventional processing pipelines.

4. **Polynomial Compression, Decompression, and Serialization:**
   Ciphertext vectors $\mathbf{u}$ and polynomial $v$ are compressed by discarding low-order bits through non-power-of-two modular divisions:
   $$\text{Compress}_d(x) = \left\lfloor \frac{2^d \cdot x + \lfloor q/2 \rfloor}{q} \right\rfloor \pmod{2^d}$$
   for $d \in \{1, 4, 5, 10, 11\}$. Direct hardware implementation of division by $q = 3329$ consumes extensive logic and latency, while bit-packing arbitrary bit-widths into byte streams introduces unaligned boundary crossings that stall pipeline flows.

5. **Timing Side-Channel Vulnerabilities and Fujisaki-Okamoto Transform:**
   In software implementations, data-dependent memory accesses during polynomial memory accesses, rejection sampling branches, and non-constant-time modular division create severe cache-timing and execution-time side-channel leakages. Most critically, IND-CCA2 security in ML-KEM decapsulation is achieved via the Fujisaki-Okamoto ($\text{FO}$) transform with implicit rejection: an invalid or tampered ciphertext must generate a deterministic pseudorandom secret $K_{reject} \leftarrow \text{SHAKE256}(z \parallel c, 32)$ rather than an explicit error. Any microarchitectural timing variation during message re-encryption or ciphertext comparison provides an active adversary with a decryption failure oracle, enabling full secret-key recovery. Dedicated hardware must guarantee perfectly constant-time execution paths independent of secret data and error states.

```
+---------------------------------------------------------------------------------------------------+
| Computational Breakdown of ML-KEM Operations                                                      |
+---------------------------------------------------------------------------------------------------+
|  1. NTT / INTT Ring Transforms  : 7-stage butterfly networks, twiddles, Barrett modular reductions|
|  2. Keccak-f[1600] Permutations : SHA3-256, SHA3-512, SHAKE-128 (XOF), SHAKE-256 (PRF/J)          |
|  3. Rejection & CBD Sampling    : Rejection rate ~18.8% for Matrix A; CBD-2 and CBD-3 for noise   |
|  4. Compression Codecs          : Fixed-point scaling mod 3329 for d in {1, 4, 5, 10, 11}         |
|  5. Fujisaki-Okamoto Transform  : Constant-time re-encryption, lockstep compare, implicit reject  |
+---------------------------------------------------------------------------------------------------+
```

## 1.3 State-of-the-Art Limitations and Critical Hardware Challenges
Designing an ASIC or FPGA accelerator for FIPS 203 involves overcoming three mutually conflicting hardware challenges:

### 1.3.1 Block RAM Utilization and Floorplan Congestion
Most prior FPGA implementations of CRYSTALS-Kyber or ML-KEM rely heavily on dedicated Block RAM (BRAM) tiles (such as AMD/Xilinx RAMB36 and RAMB18 primitives) to store polynomial coefficient arrays, precomputed NTT twiddle factor tables, Keccak sponge states, public keys, secret keys, and intermediate ciphertext buffers. Typical published accelerators consume between 8 and 36 BRAM tiles. 

However, in modern FPGA architectures, BRAM primitives are arranged in rigid, widely separated vertical columns embedded within the configurable logic block (CLB) array. As clock frequencies push beyond 300 MHz, routing long interconnect wires between distributed CLB datapaths and fixed BRAM columns causes catastrophic routing congestion, severe net delays, and timing closure failures. Furthermore, on resource-constrained embedded FPGAs, automotive silicon, and aerospace micro-devices, dedicated BRAM primitives are a scarce resource demanded by video pipelines, packet buffers, and neural network scratchpads. A monolithic accelerator that can execute all ML-KEM operations with **strictly zero BRAMs** eliminates floorplan placement constraints, mitigates routing wire delays, and allows flexible synthesis into arbitrary FPGA fabrics or standard-cell ASIC layouts.

### 1.3.2 Exorbitant DSP Consumption Limiting Edge Co-Location
Modular arithmetic over $\mathbb{Z}_q$ and polynomial pointwise multiplications typically consume dozens of dedicated digital signal processing (DSP) blocks (e.g., DSP48E2 slices). Prior art architectures frequently deploy 16, 32, 48, or even 64 DSP slices to accelerate NTT butterflies, pointwise multiplications, and Barrett reducers. On edge-tier devices (e.g., Zynq UltraScale+ MPSoC, Artix-7, or low-density Kintex devices), DSP blocks are strictly budgeted for concurrent digital signal processing, sensor fusion, radar processing, or real-time neural network inference. Cryptographic accelerators consuming a heavy DSP footprint cannot be integrated into shared edge systems without displacing core payload workloads. Restricting total DSP consumption to a minimal fixed budget (such as strictly 8 DSP slices) while sustaining multi-hundred-megahertz throughput is an open research challenge.

### 1.3.3 Multi-Security-Level Agility Without Hardware Replication
NIST FIPS 203 specifies three distinct security categories corresponding to matrix-vector module ranks $k = 2$ (ML-KEM-512), $k = 3$ (ML-KEM-768), and $k = 4$ (ML-KEM-1024), accompanied by distinct noise widths ($\eta_1, \eta_2$) and compression bit-depths ($d_u, d_v$). Many existing hardware designs are parameter-locked, supporting only ML-KEM-768 to minimize control logic complexity. When prior architectures attempt to support all three security levels, they frequently resort to parallel replicated datapaths or redundant memory structures that balloon logic area and register consumption. A truly agile hardware accelerator must achieve dynamic, single-cycle runtime parameter configuration across all three NIST security levels using a unified, shared datapath without duplicating storage or arithmetic units.

---

## 1.4 Technical Contributions of this Work
To overcome the aforementioned limitations, this paper presents **the proposed accelerator** (*proposed high-performance cryptographic accelerator*), a unified, high-frequency, all-security-level hardware accelerator for NIST FIPS 203. the proposed accelerator features an ultra-constrained physical resource budget, achieving 413.7 MHz operating frequency on AMD Kintex UltraScale while consuming **strictly zero Block RAMs (0 BRAMs)** and **strictly eight DSP slices (8 DSPs)**.

The primary technical contributions of this work are itemized as follows:

1. **Zero-BRAM Distributed Memory Architecture:**
   We design a monolithic memory subsystem synthesized entirely into CLB Distributed RAM (LUTRAM), 16-bit/32-bit Shift Register LUTs (SRLs), and CLB registers, consuming **0 BRAM36/BRAM18 tiles**. By architecting multi-bank distributed RAM structures with customized read/write address decoding, the proposed accelerator eliminates dedicated RAM column routing delays, drastically lowering wire congestion and enabling record timing closure across dense FPGA fabrics.

2. **Strictly 8-DSP Streaming Dual-Channel Karatsuba Datapath:**
   We introduce a streaming pointwise dyadic multiplier that computes four polynomial coefficients per clock cycle over the quadratic quotient rings $\mathbb{Z}_q[X]/(X^2 - \zeta^{2r+1})$. By utilizing a degree-1 Karatsuba polynomial decomposition mapped directly onto AMD DSP48E2 primitives with internal pre-adders, the multiplier achieves a fixed 24-cycle pipeline latency while consuming **strictly eight DSP48E2 slices** across all operational modes and security levels.

3. **Zero-DSP 4-Butterfly Parallel NTT/INTT Engine:**
   We propose a 4-butterfly parallel NTT/INTT transform engine that processes eight polynomial coefficients per clock cycle. Operating completely DSP-free (**0 DSPs**), the butterfly unit employs an optimized 3-chunk soft-logic multiplier tree coupled with a dedicated Barrett modular reduction stage that exploits the algebraic structure of the Kyber prime $q = 3329 = 13 \times 2^8 + 1$. Conflict-free memory access across all seven Cooley-Tukey and Gentleman-Sande stages is guaranteed by a novel 8-bank LUTRAM interleaving scheme.

4. **24-Cycle Keccak-$f[1600]$ Core with High-Throughput 64-Bit Lane Absorb:**
   We develop a unified cryptographic sponge and sampling engine supporting SHA3-256, SHA3-512, SHAKE-128, and SHAKE-256. Featuring a single-round-per-cycle permutation architecture (`FAST_24 = 1`), the engine executes the full 1600-bit permutation in exactly 24 clock cycles. A high-bandwidth 64-bit lane absorption interface and an on-the-fly rejection sampler extract up to four 12-bit valid matrix coefficients per clock beat, eliminating byte-serial throughput bottlenecks.

5. **Division-Free Canonical Signed Digit (CSD) Compression Codecs:**
   We implement an elastic, multiplier-less polynomial compression and decompression subsystem supporting runtime bit-depths $d \in \{1, 4, 5, 10, 11\}$. By converting the division by $q = 3329$ into fixed-point multiplication via $161271 \approx 2^{29}/3329$ and decomposing the constant into a Canonical Signed Digit adder tree, the codecs operate with zero DSPs and zero integer dividers.

6. **Constant-Time Fujisaki-Okamoto Transform Datapath with Implicit Rejection:**
   We construct a hardware-enforced constant-time decapsulation pipeline. Message decryption, coin derivation, full ciphertext re-encryption, and lockstep bit-level ciphertext comparison are scheduled such that execution timing is strictly deterministic. In the event of a ciphertext mismatch, the core seamlessly selects the pseudorandom rejection key $K_{reject} \leftarrow \text{SHAKE256}(z \parallel c, 32)$ without branch divergence, providing robust resistance against timing side-channel attacks and decryption failure oracles.

7. **Comprehensive Physical Implementation, Silicon Verification & Scalability:**
   We synthesize, place, route, and physically verify the proposed accelerator on an AMD Kintex UltraScale FPGA (`xcku035-ffva1156-3-e`). The core achieves a maximum post-routing clock frequency of **413.7 MHz** ($T_{clk} = 2.417$ ns) with total utilization of 29,063 LUTs (14.3%), 17,666 FFs (4.35%), 8 DSPs (0.47%), and 0 BRAMs. We demonstrate bit-exact compliance with the official NIST FIPS 203 Known Answer Tests (KAT) across ML-KEM-512, ML-KEM-768, and ML-KEM-1024, achieving execution times of 3.31–7.33 $\mu$s for KeyGen, 4.02–8.25 $\mu$s for Encapsulation, and 6.04–10.53 $\mu$s for Decapsulation.

---

## 1.5 Organization of the Paper
The remainder of this paper is structured as follows:
- **Section II** presents mathematical preliminaries, the algebraic ring setting, formal notations, parameter configurations, and complete algorithmic formulations of FIPS 203 (KeyGen, Encaps, Decaps, and the Fujisaki-Okamoto transform).
- **Section III** details the top-level unified multi-mode architecture, controller finite state machine (FSM) scheduling, memory mapping, and interface protocols.
- **Section IV** details the zero-BRAM memory hierarchy, distributed RAM mapping, and conflict-free 8-bank scheduling.
- **Section V** expounds upon the arithmetic accelerators: the 0-DSP 4-butterfly parallel NTT/INTT engine, the 8-DSP streaming Karatsuba pointwise multiplier, and the modular field ALU.
- **Section VI** describes the unified cryptographic sponge and sampling architecture: the 24-cycle Keccak-$f[1600]$ engine, 64-bit lane absorption, uniform rejection sampler, and Centered Binomial Distribution sampler.
- **Section VII** presents the multiplier-free polynomial codecs, CSD compression/decompression, and zero-bubble ping-pong serialization architecture.
- **Section VIII** reports experimental FPGA implementation results, physical timing analysis, resource breakdowns, security evaluation, and comprehensive comparative analysis against state-of-the-art literature.
- **Section IX** concludes the paper with directions for future work.

---
---

# Section II: Preliminaries and FIPS 203 Mathematical Formulation

## 2.1 Theoretical Framework and Module-LWE
NIST FIPS 203 specifies the Module-Lattice-Based Key-Encapsulation Mechanism (ML-KEM). The cryptographic security of ML-KEM is founded upon the computational hardness of the Module Learning With Errors ($\text{M-LWE}$) problem, originally introduced by Langlois and Stehlé as a generalization of standard LWE over $\mathbb{Z}_q$ and Ring-LWE over polynomial rings. 

Let $n = 256$ be the fixed polynomial degree, and let $q = 3329$ be the operational prime modulus. Define the base polynomial quotient ring:
$$\mathcal{R} = \mathbb{Z}[X] / (X^{256} + 1) \tag{1}$$
and its quotient ring modulo $q$:
$$\mathcal{R}_q = \mathbb{Z}_q[X] / (X^{256} + 1) \tag{2}$$
Elements of $\mathcal{R}_q$ are polynomials of degree at most $n - 1 = 255$ with coefficients in the finite field $\mathbb{Z}_q = \{0, 1, \dots, q - 1\}$. Polynomial addition is performed coefficient-wise in $\mathbb{Z}_q$, and polynomial multiplication is executed modulo the cyclotomic polynomial $X^{256} + 1$ with coefficients reduced modulo $q$.

The Module-LWE problem considers modules of rank $k$ over $\mathcal{R}_q$, denoted $\mathcal{R}_q^k$. Let $\chi_s$ and $\chi_e$ be error distributions over $\mathcal{R}_q$ characterized by Centered Binomial Distributions $\text{CBD}_\eta$. The decision version of the $\text{M-LWE}_{k, q, \chi}$ problem requires an adversary to distinguish between pairs $(\mathbf{A}, \mathbf{t}) \in \mathcal{R}_q^{k \times k} \times \mathcal{R}_q^k$ where:
$$\mathbf{t} = \mathbf{A} \cdot \mathbf{s} + \mathbf{e} \tag{3}$$
with secret vector $\mathbf{s} \leftarrow \chi_s^k$ and error vector $\mathbf{e} \leftarrow \chi_e^k$, and pairs $(\mathbf{A}, \mathbf{u})$ where $\mathbf{u} \leftarrow \mathcal{U}(\mathcal{R}_q^k)$ is drawn uniformly at random. The search version requires recovering secret vector $\mathbf{s}$ given $(\mathbf{A}, \mathbf{A}\mathbf{s} + \mathbf{e})$. The best known algorithms to solve Module-LWE—including primal lattice reduction (uSVP via BKZ) and dual attacks—exhibit exponential computational complexity in the lattice dimension $N = n \cdot k = 256k$.

---

## 2.2 Algebraic Ring Structure and Number Theoretic Transform
The prime modulus specified in FIPS 203 is:
$$q = 3329 = 13 \times 2^8 + 1 \tag{4}$$
Because $2^8 = 256$ divides $q - 1 = 3328$, the multiplicative group of units $\mathbb{Z}_q^*$ contains primitive roots of unity of order 256. However, $2n = 512$ does not divide $q - 1$ ($3328 / 512 = 6.5 \notin \mathbb{Z}$). Consequently, the cyclotomic polynomial $X^{256} + 1$ does *not* factor completely into linear factors over $\mathbb{Z}_q$.

Instead, let $\zeta = 17 \in \mathbb{Z}_q$ be a designated primitive 256-th root of unity modulo 3329, satisfying:
$$\zeta^{256} \equiv 1 \pmod{3329} \quad \text{and} \quad \zeta^{128} \equiv -1 \pmod{3329} \tag{5}$$
Over $\mathbb{Z}_q$, the polynomial $X^{256} + 1$ factors completely into 128 irreducible quadratic polynomials:
$$X^{256} + 1 \equiv \prod_{i=0}^{127} \left( X^2 - \zeta^{2 \cdot \text{BitRev}_7(i) + 1} \right) \pmod{3329} \tag{6}$$
where $\text{BitRev}_7(i)$ denotes the 7-bit bit-reversal of integer $i \in \{0, 1, \dots, 127\}$, defined by:
$$\text{BitRev}_7\left( \sum_{j=0}^{6} b_j 2^j \right) = \sum_{j=0}^{6} b_j 2^{6-j}, \quad b_j \in \{0, 1\} \tag{7}$$

By the Chinese Remainder Theorem (CRT), the polynomial quotient ring $\mathcal{R}_q$ is isomorphic to the direct product of 128 quadratic polynomial extension rings:
$$\mathcal{R}_q \cong \prod_{i=0}^{127} \frac{\mathbb{Z}_q[X]}{\left( X^2 - \zeta^{2 \cdot \text{BitRev}_7(i) + 1} \right)} \tag{8}$$

We denote the ring in the NTT domain by $\mathcal{T}_q$. Any polynomial $f \in \mathcal{R}_q$:
$$f(X) = \sum_{j=0}^{255} f_j X^j \in \mathcal{R}_q \tag{9}$$
is represented in $\mathcal{T}_q$ by an array of 128 degree-1 polynomials:
$$\hat{f} = \text{NTT}(f) = \left( \hat{f}_0 + \hat{f}_1 X, \, \hat{f}_2 + \hat{f}_3 X, \, \dots, \, \hat{f}_{254} + \hat{f}_{255} X \right) \in \mathcal{T}_q \tag{10}$$
where each pair $(\hat{f}_{2i}, \hat{f}_{2i+1})$ represents the polynomial:
$$\hat{f}_{2i} + \hat{f}_{2i+1} X \equiv f(X) \pmod{X^2 - \zeta^{2\cdot\text{BitRev}_7(i) + 1}} \tag{11}$$

### 2.2.1 Dyadic Base Multiplication in the Splitting Ring
Let $\hat{f}, \hat{g} \in \mathcal{T}_q$. Ring multiplication in the NTT domain, denoted by $\hat{f} \circ \hat{g}$ or $\hat{f} \times_{\mathcal{T}_q} \hat{g}$, reduces to 128 independent degree-1 polynomial base multiplications modulo $(X^2 - \gamma)$ where:
$$\gamma = \zeta^{2\cdot\text{BitRev}_7(i) + 1} \tag{12}$$
For each factor index $i \in \{0, \dots, 127\}$, let $a(X) = a_0 + a_1 X$ and $b(X) = b_0 + b_1 X$. Their modular product modulo $(X^2 - \gamma)$ is given by:
$$\begin{aligned}
a(X) \cdot b(X) &= (a_0 + a_1 X)(b_0 + b_1 X) \\
&= a_0 b_0 + (a_0 b_1 + a_1 b_0) X + a_1 b_1 X^2 \\
&\equiv (a_0 b_0 + a_1 b_1 \gamma) + (a_0 b_1 + a_1 b_0) X \pmod{X^2 - \gamma}
\end{aligned} \tag{13}$$

Thus, the dyadic base multiplication function $\text{BaseMul}(a_0, a_1, b_0, b_1, \gamma) = (c_0, c_1)$ is explicitly formulated as:
$$\begin{cases}
c_0 = a_0 b_0 + a_1 b_1 \gamma \pmod{3329} \\
c_1 = a_0 b_1 + a_1 b_0 \pmod{3329}
\end{cases} \tag{14}$$

Using Karatsuba's multiplication algorithm, the cross-term $(a_0 b_1 + a_1 b_0)$ can be computed using three base multiplications:
$$a_0 b_1 + a_1 b_0 = (a_0 + a_1)(b_0 + b_1) - a_0 b_0 - a_1 b_1 \tag{15}$$
enabling an efficient, low-DSP datapath mapping.

---

## 2.3 Mathematical Notation and Operational Symbols
To maintain rigorous mathematical conformity with NIST FIPS 203 and IEEE Transactions standards, the formal notations employed throughout this paper are defined in Table I.

### Table I: Mathematical Notation and Symbols
| Symbol | Mathematical Domain / Type | Definition and Algorithmic Meaning | FIPS 203 Ref. |
| :--- | :--- | :--- | :--- |
| $q$ | $\mathbb{Z}^+$ | Modulus of the polynomial quotient ring, $q = 3329$. | Section 2.1 |
| $n$ | $\mathbb{Z}^+$ | Degree of polynomials, fixed at $n = 256$. | Section 2.1 |
| $k$ | $\{2, 3, 4\}$ | Module rank (vector dimension) defining security level. | Table 1 |
| $\mathcal{R}$ | $\mathbb{Z}[X]/(X^n+1)$ | Cyclotomic integer polynomial quotient ring. | Section 2.1 |
| $\mathcal{R}_q$ | $\mathbb{Z}_q[X]/(X^n+1)$ | Base polynomial quotient ring modulo $q$. | Section 2.1 |
| $\mathcal{T}_q$ | $\prod_{i=0}^{127} \mathbb{Z}_q[X]/(X^2-\gamma_i)$ | Polynomial ring $\mathcal{R}_q$ transformed into the NTT domain. | Section 2.1 |
| $\mathbf{a}, \mathbf{s}, \mathbf{e}$ | $\mathcal{R}_q^k$ | Column vectors of $k$ polynomials in the spatial domain. | Section 2.1 |
| $\mathbf{A}$ | $\mathcal{R}_q^{k \times k}$ | Square matrix of $k \times k$ polynomials. | Section 2.1 |
| $\mathbf{A}^T$ | $\mathcal{R}_q^{k \times k}$ | Matrix transpose of $\mathbf{A}$. | Section 2.1 |
| $\hat{a}, \hat{\mathbf{a}}, \hat{\mathbf{A}}$ | $\mathcal{T}_q, \mathcal{T}_q^k, \mathcal{T}_q^{k \times k}$ | Elements transformed into the NTT domain (circumflex accent). | Section 2.1 |
| $\hat{f} \circ \hat{g}$ | $\mathcal{T}_q \times \mathcal{T}_q \to \mathcal{T}_q$ | Dyadic pointwise base product over 128 quadratic factors. | Algorithm 11, 12 |
| $\hat{\mathbf{A}} \circ \hat{\mathbf{s}}$ | $\mathcal{T}_q^{k \times k} \times \mathcal{T}_q^k \to \mathcal{T}_q^k$ | Matrix-vector multiplication using dyadic base products. | Algorithms 13, 14 |
| $\mathbb{B}$ | $\{0, 1, \dots, 255\}$ | Finite set of 8-bit bytes ($\{0, 1\}^8$). | Section 2.3 |
| $\mathbb{B}^L$ | Byte array | Array of $L$ bytes, indexed as $B[0], B[1], \dots, B[L-1]$. | Section 2.3 |
| $a \parallel b$ | String concatenation | Concatenation of bit-strings or byte-arrays. | Section 2.3 |
| $\text{BitRev}_7(i)$ | $\{0, \dots, 127\} \to \{0, \dots, 127\}$ | 7-bit bit-reversal permutation function. | Section 2.3 |
| $\zeta$ | $\mathbb{Z}_q$ | Primitive 256-th root of unity modulo 3329, $\zeta = 17$. | Section 2.3 |
| $\lfloor x \rceil$ | $\mathbb{R} \to \mathbb{Z}$ | Rounding to the nearest integer, $\lfloor x + 1/2 \rfloor$. | Section 2.3 |
| $\lfloor x \rfloor$ | $\mathbb{R} \to \mathbb{Z}$ | Floor function: largest integer less than or equal to $x$. | Section 2.3 |
| $a \bmod^{\pm} q$ | $\mathbb{Z} \to [-\lfloor q/2 \rfloor, \lfloor q/2 \rfloor]$ | Centered modulo reduction into range $\{-1664, \dots, 1664\}$. | Section 2.3 |
| $\text{Compress}_d$ | $\mathbb{Z}_q \to \mathbb{Z}_{2^d}$ | Lossy coefficient compression function discarding low-order bits. | Section 4.2.1 |
| $\text{Decompress}_d$| $\mathbb{Z}_{2^d} \to \mathbb{Z}_q$ | Coefficient decompression mapping recovering spatial elements. | Section 4.2.1 |
| $\text{ByteEncode}_d$| $\mathbb{Z}_{2^d}^{256} \to \mathbb{B}^{32d}$ | Bit-packing 256 $d$-bit coefficients into a contiguous byte stream. | Algorithm 5 |
| $\text{ByteDecode}_d$| $\mathbb{B}^{32d} \to \mathbb{Z}_{2^d}^{256}$ | Unpacking contiguous byte stream into 256 $d$-bit coefficients. | Algorithm 6 |
| $\text{SampleNTT}$ | $\mathbb{B}^* \to \mathcal{T}_q$ | Uniform rejection sampling from SHAKE-128 squeeze stream. | Algorithm 7 |
| $\text{SamplePolyCBD}_\eta$| $\mathbb{B}^{64\eta} \to \mathcal{R}_q$ | Centered Binomial Distribution sampling from SHAKE-256 stream. | Algorithm 8 |
| $G$ | $\mathbb{B}^* \to \mathbb{B}^{64}$ | Cryptographic hash function SHA3-512. | Section 4.1 |
| $H$ | $\mathbb{B}^* \to \mathbb{B}^{32}$ | Cryptographic hash function SHA3-256. | Section 4.1 |
| $J$ | $\mathbb{B}^* \to \mathbb{B}^{32}$ | Extendable output function SHAKE-256 (32-byte squeeze). | Section 4.1 |
| $\text{PRF}_\eta(s, b)$ | $\mathbb{B}^{32} \times \mathbb{B} \to \mathbb{B}^{64\eta}$ | Pseudorandom function: $\text{SHAKE256}(s \parallel b, 64\eta)$. | Section 4.1 |
| $\text{XOF}(\rho, i, j)$ | $\mathbb{B}^{32} \times \mathbb{B} \times \mathbb{B} \to \mathbb{B}^*$ | Extendable-output function: $\text{SHAKE128}(\rho \parallel i \parallel j)$. | Section 4.1 |

---

## 2.4 Cryptographic Parameter Sets and Security Categories
NIST FIPS 203 specifies three distinct operational parameter configurations targeting varying security categories as defined in NIST's post-quantum evaluation criteria. These parameter sets are formally mapped in Table II.

### Table II: FIPS 203 Parameter Sets and Security Mappings
| Parameter Specification | Symbol | ML-KEM-512 | ML-KEM-768 | ML-KEM-1024 |
| :--- | :--- | :--- | :--- | :--- |
| **NIST Security Category** | — | Category 1 | Category 3 | Category 5 |
| **Equivalent Classical Hardness**| — | AES-128 / SHA-256 | AES-192 / SHA-384 | AES-256 / SHA-512 |
| **Equivalent Quantum Hardness** | — | Exhaustive Key Search | Exhaustive Key Search | Exhaustive Key Search |
| **Module Rank** | $k$ | **2** | **3** | **4** |
| **Polynomial Degree** | $n$ | 256 | 256 | 256 |
| **Operating Modulus** | $q$ | 3329 | 3329 | 3329 |
| **Secret Noise Width** | $\eta_1$ | **3** | **2** | **2** |
| **Ciphertext Noise Width** | $\eta_2$ | **2** | **2** | **2** |
| **Vector Compression Depth** | $d_u$ | **10** | **10** | **11** |
| **Scalar Compression Depth** | $d_v$ | **4** | **4** | **5** |
| **Public Encapsulation Key ($ek$)** | $384k + 32$ | **800 Bytes** | **1,184 Bytes** | **1,568 Bytes** |
| **Private Decapsulation Key ($dk$)**| $768k + 96$ | **1,632 Bytes** | **2,400 Bytes** | **3,168 Bytes** |
| **Ciphertext Size ($c$)** | $32(k \cdot d_u + d_v)$ | **768 Bytes** | **1,088 Bytes** | **1,568 Bytes** |
| — *Ciphertext Vector ($c_1$)* | $32 \cdot k \cdot d_u$ | 640 Bytes | 960 Bytes | 1,408 Bytes |
| — *Ciphertext Scalar ($c_2$)* | $32 \cdot d_v$ | 128 Bytes | 128 Bytes | 160 Bytes |
| **Shared Secret Size ($K$)** | — | **32 Bytes** (256 bits) | **32 Bytes** (256 bits) | **32 Bytes** (256 bits) |
| **Decapsulation Failure Probability** | $\delta$ | $2^{-139}$ | $2^{-164}$ | $2^{-174}$ |

The three security categories correspond to the classical and quantum difficulty of key search:
- **ML-KEM-512 ($k = 2$):** Designed to match or exceed the computational difficulty of breaking AES-128 via exhaustive key search (NIST Security Category 1). The noise width $\eta_1 = 3$ provides an expanded variance for secret vectors $\mathbf{s}, \mathbf{e}$ to compensate for the smaller module dimension $256 \times 2 = 512$.
- **ML-KEM-768 ($k = 3$):** Matches the security of AES-192 (Category 3). With module dimension $256 \times 3 = 768$, it represents the recommended general-purpose baseline for global post-quantum migration.
- **ML-KEM-1024 ($k = 4$):** Matches the security of AES-256 (Category 5). Provides the highest security margin against advanced quantum attacks, utilizing an increased vector compression depth $d_u = 11$ and scalar depth $d_v = 5$.

---

## 2.5 Fundamental Auxiliary Building Blocks

### 2.5.1 Coefficient Compression and Decompression
To reduce transmission overhead over public channels, ciphertext components are compressed. For an integer $x \in \mathbb{Z}_q$ and bit depth $d < 12$, the lossy compression function $\text{Compress}_d: \mathbb{Z}_q \to \mathbb{Z}_{2^d}$ is defined by:
$$\text{Compress}_d(x) = \left\lfloor \frac{2^d \cdot x + \lfloor q/2 \rfloor}{q} \right\rfloor \pmod{2^d} = \left\lfloor \frac{2^d \cdot x + 1664}{3329} \right\rfloor \bmod 2^d \tag{16}$$
The corresponding decompression function $\text{Decompress}_d: \mathbb{Z}_{2^d} \to \mathbb{Z}_q$ projects compressed integers back into the ring $\mathbb{Z}_q$:
$$\text{Decompress}_d(y) = \left\lfloor \frac{q \cdot y + 2^{d-1}}{2^d} \right\rfloor = \left\lfloor \frac{3329 \cdot y + 2^{d-1}}{2^d} \right\rfloor \tag{17}$$

When applied to polynomials $f \in \mathcal{R}_q$ or polynomial vectors $\mathbf{u} \in \mathcal{R}_q^k$, $\text{Compress}_d$ and $\text{Decompress}_d$ operate independently on each individual coefficient. The approximation error $|x' - x \bmod^{\pm} q|$ introduced by compression and decompression is bounded by:
$$|x' - x \bmod^{\pm} q| \le \left\lfloor \frac{q}{2^{d+1}} \right\rceil \tag{18}$$
which is accounted for within the noise budget during decryption.

### 2.5.2 Byte Encoding and Decoding
Polynomial coefficients in spatial or NTT domain are encoded into contiguous byte arrays.
- $\text{ByteEncode}_d: \mathbb{Z}_{2^d}^{256} \to \mathbb{B}^{32d}$: Converts 256 $d$-bit integers $F[0], \dots, F[255]$ into an array of $32d$ bytes ($256d$ bits). Each integer is serialized into $d$ consecutive bits in little-endian order.
  - For uncompressed coefficients ($d = 12$), 2 coefficients span exactly 3 bytes (24 bits):
    $$B[3i] = F[2i] \bmod 256, \quad B[3i+1] = \lfloor F[2i]/256 \rfloor + 16(F[2i+1] \bmod 16), \quad B[3i+2] = \lfloor F[2i+1]/16 \rfloor \tag{19}$$
- $\text{ByteDecode}_d: \mathbb{B}^{32d} \to \mathbb{Z}_{2^d}^{256}$: Unpacks $32d$ bytes into 256 $d$-bit integers.
  - For $d = 12$, decoding inverts (19):
    $$F[2i] = B[3i] + 256(B[3i+1] \bmod 16), \quad F[2i+1] = \lfloor B[3i+1]/16 \rfloor + 16 B[3i+2] \tag{20}$$

### 2.5.3 Uniform Rejection Sampling ($\text{SampleNTT}$)
Public matrix $\hat{\mathbf{A}}$ is sampled directly into the NTT domain from the output stream of an extendable output function $\text{XOF}(\rho, i, j) = \text{SHAKE128}(\rho \parallel i \parallel j)$. Algorithm 1 details the uniform rejection sampling procedure:

```
Algorithm 1: SampleNTT(B) (FIPS 203 Algorithm 5)
Input:  Byte stream B = B[0], B[1], B[2], ... in B*
Output: Polynomial a_hat in T_q with 256 coefficients
--------------------------------------------------------------------------------
1:  i <-- 0
2:  j <-- 0
3:  while i < 256 do
4:      d1 <-- B[3j]   + 256 * (B[3j+1] mod 16)
5:      d2 <-- floor(B[3j+1] / 16) + 16 * B[3j+2]
6:      if d1 < q then
7:          a_hat[i] <-- d1
8:          i <-- i + 1
9:      end if
10:     if d2 < q and i < 256 then
11:         a_hat[i] <-- d2
12:         i <-- i + 1
13:     end if
14:     j <-- j + 1
15: end while
16: return a_hat
```

Each 3-byte input slice yields two candidate 12-bit integers $d_1, d_2 \in [0, 4095]$. A candidate is accepted if and only if $d < 3329$. Because $3329 / 4096 \approx 81.28\%$, the theoretical rejection rate is $18.72\%$.

### 2.5.4 Centered Binomial Distribution Sampling ($\text{SamplePolyCBD}_\eta$)
Secret and error polynomials are drawn from the Centered Binomial Distribution with parameter $\eta \in \{2, 3\}$. Given $64\eta$ pseudo-random bytes $B \in \mathbb{B}^{64\eta}$ produced by $\text{PRF}_\eta(\sigma, N) = \text{SHAKE256}(\sigma \parallel N, 64\eta)$, the byte stream is converted to $512\eta$ bits $\beta_0, \beta_1, \dots, \beta_{512\eta - 1}$. Algorithm 2 details the sampling:

```
Algorithm 2: SamplePolyCBD_eta(B) (FIPS 203 Algorithm 6)
Input:  Byte array B in B^(64*eta)
Output: Polynomial f in R_q
--------------------------------------------------------------------------------
1:  (beta_0, beta_1, ..., beta_{512*eta - 1}) <-- BytesToBits(B)
2:  for i = 0 to 255 do
3:      x <-- sum_{j=0}^{eta-1} beta_{2*i*eta + j}
4:      y <-- sum_{j=0}^{eta-1} beta_{2*i*eta + eta + j}
5:      f[i] <-- (x - y) mod q
6:  end for
7:  return f
```
The resulting coefficients follow the centered binomial distribution:
$$f_i = \sum_{j=0}^{\eta-1} a_j - \sum_{j=0}^{\eta-1} b_j \in \{-\eta, \dots, \eta\} \pmod q \tag{21}$$
with mean $\mathbb{E}[f_i] = 0$ and variance $\text{Var}(f_i) = \eta / 2$. Specifically, for $\eta = 2$, $\text{Var} = 1.0$; for $\eta = 3$, $\text{Var} = 1.5$.

---

## 2.6 Complete Cryptographic Workflows of FIPS 203

FIPS 203 defines the Key-Encapsulation Mechanism in a modular hierarchy: an underlying Chosen-Plaintext Attack secure Public-Key Encryption scheme ($\text{K-PKE}$) is encapsulated within the Chosen-Ciphertext Attack secure Key-Encapsulation Mechanism ($\text{ML-KEM}$) via the Fujisaki-Okamoto transform.

```
+---------------------------------------------------------------------------------------------------+
| NIST FIPS 203 Structural Hierarchy & Transformation Model                                         |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|  +---------------------------------------------------------------------------------------------+  |
|  |                            ML-KEM Key-Encapsulation Mechanism                               |  |
|  |                   (IND-CCA2 Secure via Fujisaki-Okamoto Transform)                          |  |
|  |                                                                                             |  |
|  |   ML-KEM.KeyGen (Alg 16/19)      ML-KEM.Encaps (Alg 17/20)      ML-KEM.Decaps (Alg 18/21)   |  |
|  |                                                                                             |  |
|  |   +-------------------------------------------------------------------------------------+   |  |
|  |   |                Underlying K-PKE Public-Key Encryption Scheme                        |   |  |
|  |   |                           (IND-CPA Secure)                                          |   |  |
|  |   |                                                                                     |   |  |
|  |   |   K-PKE.KeyGen (Alg 13)       K-PKE.Encrypt (Alg 14)        K-PKE.Decrypt (Alg 15)  |   |  |
|  |   +-------------------------------------------------------------------------------------+   |  |
|  +---------------------------------------------------------------------------------------------+  |
+---------------------------------------------------------------------------------------------------+
```

### 2.6.1 The Underlying Public-Key Encryption Scheme ($\text{K-PKE}$)

#### 1. Key Generation ($\text{K-PKE.KeyGen}$, Algorithm 13):
Given a 32-byte seed $d \in \mathbb{B}^{32}$:
1. Compute seed expansion:
   $$(\rho, \sigma) \leftarrow G(d \parallel k) = \text{SHA3-512}(d \parallel k) \tag{22}$$
2. Generate public matrix $\hat{\mathbf{A}} \in \mathcal{T}_q^{k \times k}$:
   $$\hat{\mathbf{A}}[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, j, i)) \quad \text{for } i, j \in \{0, \dots, k - 1\} \tag{23}$$
3. Sample secret vector $\mathbf{s} \in \mathcal{R}_q^k$ and error vector $\mathbf{e} \in \mathcal{R}_q^k$:
   $$\mathbf{s}[i] \leftarrow \text{SamplePolyCBD}_{\eta_1}(\text{PRF}(\sigma, N)), \quad N \leftarrow N + 1 \tag{24}$$
   $$\mathbf{e}[i] \leftarrow \text{SamplePolyCBD}_{\eta_1}(\text{PRF}(\sigma, N)), \quad N \leftarrow N + 1 \tag{25}$$
4. Transform into the NTT domain:
   $$\hat{\mathbf{s}} \leftarrow \text{NTT}(\mathbf{s}), \quad \hat{\mathbf{e}} \leftarrow \text{NTT}(\mathbf{e}) \tag{26}$$
5. Compute public vector:
   $$\hat{\mathbf{t}} \leftarrow \hat{\mathbf{A}} \circ \hat{\mathbf{s}} + \hat{\mathbf{e}} \in \mathcal{T}_q^k \tag{27}$$
6. Serialize keys:
   $$ek_{PKE} \leftarrow \text{ByteEncode}_{12}(\hat{\mathbf{t}}) \parallel \rho \tag{28}$$
   $$dk_{PKE} \leftarrow \text{ByteEncode}_{12}(\hat{\mathbf{s}}) \tag{29}$$

#### 2. Encryption ($\text{K-PKE.Encrypt}$, Algorithm 14):
Given public key $ek_{PKE} \in \mathbb{B}^{384k + 32}$, message $m \in \mathbb{B}^{32}$, and randomness $r \in \mathbb{B}^{32}$:
1. Unpack public key:
   $$\hat{\mathbf{t}} \leftarrow \text{ByteDecode}_{12}(ek_{PKE}[0 : 384k]), \quad \rho \leftarrow ek_{PKE}[384k : 384k + 32] \tag{30}$$
2. Reconstruct transposed matrix $\hat{\mathbf{A}}^T \in \mathcal{T}_q^{k \times k}$:
   $$\hat{\mathbf{A}}^T[i, j] \leftarrow \text{SampleNTT}(\text{XOF}(\rho, i, j)) \quad \text{for } i, j \in \{0, \dots, k - 1\} \tag{31}$$
3. Sample random vector $\mathbf{r} \in \mathcal{R}_q^k$ and error vectors $\mathbf{e}_1 \in \mathcal{R}_q^k, e_2 \in \mathcal{R}_q$:
   $$\mathbf{r}[i] \leftarrow \text{SamplePolyCBD}_{\eta_1}(\text{PRF}(r, N)), \quad N \leftarrow N + 1 \tag{32}$$
   $$\mathbf{e}_1[i] \leftarrow \text{SamplePolyCBD}_{\eta_2}(\text{PRF}(r, N)), \quad N \leftarrow N + 1 \tag{33}$$
   $$e_2 \leftarrow \text{SamplePolyCBD}_{\eta_2}(\text{PRF}(r, N)) \tag{34}$$
4. Transform random vector into NTT domain:
   $$\hat{\mathbf{r}} \leftarrow \text{NTT}(\mathbf{r}) \tag{35}$$
5. Compute ciphertext vector $\mathbf{u}$ and polynomial $v$:
   $$\mathbf{u} \leftarrow \text{INTT}(\hat{\mathbf{A}}^T \circ \hat{\mathbf{r}}) + \mathbf{e}_1 \in \mathcal{R}_q^k \tag{36}$$
   $$v \leftarrow \text{INTT}(\hat{\mathbf{t}}^T \circ \hat{\mathbf{r}}) + e_2 + \text{Decompress}_1(\text{ByteDecode}_1(m)) \in \mathcal{R}_q \tag{37}$$
6. Compress and serialize ciphertext $c = c_1 \parallel c_2$:
   $$c_1 \leftarrow \text{ByteEncode}_{d_u}(\text{Compress}_{d_u}(\mathbf{u})) \tag{38}$$
   $$c_2 \leftarrow \text{ByteEncode}_{d_v}(\text{Compress}_{d_v}(v)) \tag{39}$$
   $$c \leftarrow c_1 \parallel c_2 \tag{40}$$

#### 3. Decryption ($\text{K-PKE.Decrypt}$, Algorithm 15):
Given secret key $dk_{PKE} \in \mathbb{B}^{384k}$ and ciphertext $c \in \mathbb{B}^{32(k \cdot d_u + d_v)}$:
1. Decompress and unpack ciphertext:
   $$\mathbf{u} \leftarrow \text{Decompress}_{d_u}(\text{ByteDecode}_{d_u}(c[0 : 32k \cdot d_u])) \tag{41}$$
   $$v \leftarrow \text{Decompress}_{d_v}(\text{ByteDecode}_{d_v}(c[32k \cdot d_u : 32(k \cdot d_u + d_v)])) \tag{42}$$
2. Unpack secret key:
   $$\hat{\mathbf{s}} \leftarrow \text{ByteDecode}_{12}(dk_{PKE}) \tag{43}$$
3. Recover message:
   $$w \leftarrow v - \text{INTT}(\hat{\mathbf{s}}^T \circ \text{NTT}(\mathbf{u})) \in \mathcal{R}_q \tag{44}$$
   $$m \leftarrow \text{ByteEncode}_1(\text{Compress}_1(w)) \in \mathbb{B}^{32} \tag{45}$$

---

### 2.6.2 ML-KEM Key Generation (`ML-KEM.KeyGen`)
The top-level key generation algorithm $\text{ML-KEM.KeyGen}$ (Algorithm 19) draws two uniform 32-byte seeds $d, z \leftarrow \mathcal{U}(\mathbb{B}^{32})$ from a hardware cryptographically secure random number generator (TRNG) and invokes internal key generation (Algorithm 16).

```
Algorithm 3: ML-KEM.KeyGen_internal(d, z) (FIPS 203 Algorithm 16)
Input:  Random seeds d in B^32, z in B^32
Output: Encapsulation key ek in B^(384*k + 32),
        Decapsulation key dk in B^(768*k + 96)
--------------------------------------------------------------------------------
1:  (ek_PKE, dk_PKE) <-- K-PKE.KeyGen(d)
2:  ek <-- ek_PKE
3:  dk <-- dk_PKE || ek || H(ek) || z
4:  return (ek, dk)
```

The composition of the secret decapsulation key is:
$$dk = \underbrace{\text{ByteEncode}_{12}(\hat{\mathbf{s}})}_{384k\text{ Bytes}} \parallel \underbrace{ek}_{384k + 32\text{ Bytes}} \parallel \underbrace{H(ek)}_{32\text{ Bytes}} \parallel \underbrace{z}_{32\text{ Bytes}} \tag{46}$$
yielding a total size of $768k + 96$ bytes. Storing $ek$ and its hash $h = H(ek) = \text{SHA3-256}(ek)$ directly inside $dk$ accelerates decapsulation by avoiding re-computation during the Fujisaki-Okamoto verification.

---

### 2.6.3 ML-KEM Key Encapsulation (`ML-KEM.Encaps`)
Key encapsulation accepts the recipient's encapsulation key $ek$ and a 32-byte ephemeral randomness seed $m \leftarrow \mathcal{U}(\mathbb{B}^{32})$, and outputs a ciphertext $c$ and a shared secret key $K \in \mathbb{B}^{32}$.

```
Algorithm 4: ML-KEM.Encaps_internal(ek, m) (FIPS 203 Algorithm 17)
Input:  Encapsulation key ek in B^(384*k + 32),
        Ephemeral message m in B^32
Output: Ciphertext c in B^(32*(k*d_u + d_v)),
        Shared secret K in B^32
--------------------------------------------------------------------------------
1:  // Key validation: verify ek length and coefficient validity
2:  if ByteEncode_12(ByteDecode_12(ek[0 : 384*k])) != ek[0 : 384*k] then
3:      return error
4:  end if
5:  (K_hat, r) <-- G(m || H(ek))
6:  c <-- K-PKE.Encrypt(ek, m, r)
7:  K <-- K_hat
8:  return (c, K)
```

The ephemeral randomness $m$ and the public key digest $H(ek)$ are hashed together:
$$(\hat{K}, r) \leftarrow G(m \parallel H(ek)) = \text{SHA3-512}(m \parallel H(ek)) \tag{47}$$
where $\hat{K} \in \mathbb{B}^{32}$ serves as the tentative shared secret, and $r \in \mathbb{B}^{32}$ acts as the deterministic seed for noise generation in $\text{K-PKE.Encrypt}$.

---

### 2.6.4 ML-KEM Key Decapsulation (`ML-KEM.Decaps`) & The Fujisaki-Okamoto Transform
Decapsulation transforms the CPA-secure encryption scheme into a CCA2-secure key encapsulation mechanism using the Fujisaki-Okamoto ($\text{FO}$) transform with implicit rejection.

```
Algorithm 5: ML-KEM.Decaps_internal(dk, c) (FIPS 203 Algorithm 18)
Input:  Decapsulation key dk in B^(768*k + 96),
        Ciphertext c in B^(32*(k*d_u + d_v))
Output: Shared secret K in B^32
--------------------------------------------------------------------------------
1:  // Parse decapsulation key components
2:  dk_PKE <-- dk[0 : 384*k]
3:  ek     <-- dk[384*k : 768*k + 32]
4:  h      <-- dk[768*k + 32 : 768*k + 64]
5:  z      <-- dk[768*k + 64 : 768*k + 96]
6:
7:  // Step 1: Decrypt candidate message
8:  m' <-- K-PKE.Decrypt(dk_PKE, c)
9:
10: // Step 2: Re-derive coins and tentative secret
11: (K_hat', r') <-- G(m' || h)
12:
13: // Step 3: Compute pseudorandom rejection key
14: K_reject <-- J(z || c) = SHAKE256(z || c, 32)
15:
16: // Step 4: Re-encrypt candidate message
17: c' <-- K-PKE.Encrypt(ek, m', r')
18:
19: // Step 5: Constant-Time Ciphertext Verification & Secret Selection
20: if c' == c then
21:     return K_hat'
22: else
23:     return K_reject
24: end if
```

```
+---------------------------------------------------------------------------------------------------+
| Fujisaki-Okamoto Transform with Implicit Rejection (Decapsulation Flow)                           |
+---------------------------------------------------------------------------------------------------+
|                                                                                                   |
|           Ciphertext c                                      dk = (s_hat, ek, h, z)                |
|                |                                                       |                          |
|                +-----------------------+                               |                          |
|                |                       |                               |                          |
|                v                       v                               v                          |
|       +-----------------+     +-----------------+             +-----------------+                 |
|       |  K-PKE.Decrypt  | <-- |   Parse dk_PKE  |             |  Parse z, h, ek |                 |
|       +-----------------+     +-----------------+             +-----------------+                 |
|                |                                                       |                          |
|                v Candidate m'                                          |                          |
|       +----------------------------------------------------------------+                          |
|       |                                                                                           |
|       v                                                                                           |
|  +--------------------+                                      +--------------------+               |
|  | G(m' || h) SHA3-512|                                      | J(z || c) SHAKE256 |               |
|  +--------------------+                                      +--------------------+               |
|       |          |                                                     |                          |
|       v          v                                                     v                          |
|   Secret K_hat' Coins r'                                       Rejection Key K_reject             |
|       |          |                                                     |                          |
|       |          v                                                     |                          |
|       |  +--------------------+                                        |                          |
|       |  |   K-PKE.Encrypt    | <-- ek                                 |                          |
|       |  +--------------------+                                        |                          |
|       |          |                                                     |                          |
|       |          v Regenerated Ciphertext c'                           |                          |
|       |          |                                                     |                          |
|       |          +----------------------------+                        |                          |
|       |                                       |                        |                          |
|       |                                       v                        |                          |
|       |                             +-------------------+              |                          |
|       |                             | Lockstep Compare  | <--- c       |                          |
|       |                             |    (c' == c ?)    |              |                          |
|       |                             +-------------------+              |                          |
|       |                                       |                        |                          |
|       |                                       v select flag            |                          |
|       |                             +-------------------+              |                          |
|       +---------------------------> | Constant-Time Mux | <------------+                          |
|                                     +-------------------+                                         |
|                                               |                                                   |
|                                               v                                                   |
|                                      Final Shared Secret K                                        |
+---------------------------------------------------------------------------------------------------+
```

#### Detailed Cryptographic Rationale for Implicit Rejection:
The security proof of ML-KEM in the Quantum Random Oracle Model (QROM) requires that an active chosen-ciphertext attacker cannot learn any secret-key information by querying invalid ciphertexts. If an implementation were to return an explicit error flag $\bot$ upon verification failure ($c' \neq c$), or if the hardware exhibited timing variations depending on whether decryption succeeded or where the mismatch occurred, the adversary could construct a chosen-ciphertext decryption failure oracle. By iteratively perturbing ciphertext coefficients and observing failure rates, an attacker could reconstruct the secret vector $\mathbf{s}$.

Under the implicit rejection paradigm formalized in FIPS 203:
1. When $c' = c$, the legitimate shared secret $K = \hat{K}'$ is returned;
2. When $c' \neq c$, the accelerator outputs a deterministic pseudorandom key:
   $$K_{reject} \leftarrow \text{SHAKE256}(z \parallel c, 32) \tag{48}$$
   derived from the private seed $z$ and the exact received ciphertext $c$.

Because $z$ is uniform and private, $K_{reject}$ is indistinguishable from a random 256-bit string to any observer lacking $z$. Any modified ciphertext yields a unique, pseudorandom, and cryptographically useless shared key, completely blinding the adversary. Crucially, the hardware must execute lines 8–24 of Algorithm 5 in **strictly constant time**, ensuring that power profiles, EM emissions, and clock cycle latencies remain completely invariant to whether $c' = c$ or $c' \neq c$.
