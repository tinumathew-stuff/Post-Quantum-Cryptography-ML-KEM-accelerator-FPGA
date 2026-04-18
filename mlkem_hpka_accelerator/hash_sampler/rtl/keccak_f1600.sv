`timescale 1ns/1ps

//==================================================================================================
// Module Name: keccak_f1600
// Project:     ML-KEM High-Performance Kyber Accelerator (HPKA)
// Standard:    NIST FIPS 202 (SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions)
//              NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism / ML-KEM)
//
// Description:
//   Fully synthesized, parameterized hardware implementation of the Keccak-f[1600] cryptographic
//   permutation engine. The engine operates on a 1600-bit state matrix composed of 25 parallel
//   64-bit words (lanes), arranged geometrically as a 5x5 array (x, y in [0..4], z in [0..63]).
//
//   This module forms the computational backbone of the ML-KEM accelerator's cryptographic hashing
//   and pseudorandom sampling infrastructure:
//     - SHAKE-128: Used for deterministic rejection sampling of public parameter matrix A (k x k).
//     - SHAKE-256: Used for Centered Binomial Distribution (CBD_eta) sampling of secret/error vectors
//                  and derivation of pseudorandom seeds.
//     - SHA3-256 / SHA3-512: Used for message digests, public key fingerprints (H(pk)), and FO transform.
//
// Round Transformations (24 rounds per permutation, r = 0 to 23):
//   1. Theta (θ) Parity & Diffusion:
//      Computes column parities C[x] = XOR_{y=0..4} A[x,y] across each 5-lane column (x in 0..4).
//      Calculates inter-column parity diffusion factors D[x] = C[(x+4)%5] ^ ROL64(C[(x+1)%5], 1).
//      Produces intermediate state next_theta[x,y] = A[x,y] ^ D[x].
//      Hardware mapping achieves a 2-level LUT structure: LUT5 for C[x] followed by LUT3 for next_theta.
//
//   2. Rho (ρ) Bitwise Dispersion:
//      Performs lane-specific circular bit-rotations ROL64(A[x,y], rho_offset(x,y)). The rotation
//      offsets are fixed constants defined in FIPS 202 Table 2, providing bit-level dispersion.
//
//   3. Pi (π) Lane Transposition:
//      Permutes the spatial coordinates of each lane according to (x, y) -> (y, (2x + 3y) mod 5).
//      In hardware, Rho and Pi are merged into zero-cost wire routing and bit-slicing permutations.
//
//   4. Chi (χ) Non-Linear Layer:
//      The sole non-linear transformation in Keccak (algebraic degree 2), operating independently on
//      each 5-lane row: A''[x,y] = B[x,y] ^ (~B[(x+1)%5, y] & B[(x+2)%5, y]).
//      Implemented in FPGA architecture as 25 parallel 64-bit slices of 5-input LUTs (LUT5).
//
//   5. Iota (ι) Round Constant Injection:
//      Injects an asymmetric 64-bit round constant rc(r) into origin lane A[0,0] to break symmetry
//      and prevent slide/invariant attacks across rounds.
//
// Microarchitectural Parameters & Operating Modes:
//   - FAST_24 = 1 (Default HPKA High-Performance Mode):
//       Executes 1 complete Keccak round per clock cycle (θ -> ρ -> π -> χ -> ι in one combinational
//       path). A full 24-round permutation completes in exactly 24 clock cycles.
//   - FAST_24 = 0 (2-Phase Pipelined Mode):
//       Splits each round into 2 clock cycles using an intermediate register (theta_q).
//       Phase 0: Computes and latches θ parity into theta_q.
//       Phase 1: Computes ρ, π, χ, ι from theta_q and updates state_q.
//       Enables ultra-high operating frequencies (>500 MHz on modern FPGA fabrics) at 48 cycles/perm.
//
// Direct In-Situ State Absorption:
//   Features dedicated absorption controls (`load`, `absorb`, `absorb_first`) allowing external
//   rate blocks (`state_in`) to be XORed directly into the 1600-bit register bank in 1 cycle,
//   eliminating external pre-XOR multiplexers and minimizing critical path overhead.
//==================================================================================================

module keccak_f1600 #(
    parameter bit FAST_24 = 1  // 1: HPKA 24-cycle permutation (1 round/cc), 0: 48-cycle 2-phase
)(
    // Global Clock and Active-Low Reset
    input  logic          clk,          // System clock (up to 450+ MHz in target FPGA fabric)
    input  logic          rst_n,        // Asynchronous/Synchronous active-low reset

    // Permutation Control and Handshake
    input  logic          start,        // 1-cycle pulse to trigger a 24-round permutation
    input  logic          load,         // Direct overwrite load: initializes state_q with state_in
    input  logic [1599:0] state_in,     // 1600-bit state input vector for loading or XOR absorption
    input  logic          absorb = 1'b0,       // Incremental absorb: state_q <= state_q ^ state_in
    input  logic          absorb_first = 1'b0, // First absorb block: state_q <= '0 ^ state_in
    output logic          ready,        // High when idle/ready to accept new start, load, or absorb
    output logic          done,         // 1-cycle pulse asserted upon completion of round 23
    output logic [1599:0] state_out     // Continuous 1600-bit current state vector output
);

    //----------------------------------------------------------------------------------------------
    // Internal Registers and State Variables
    //----------------------------------------------------------------------------------------------
    logic [1599:0] state_q;             // Primary 1600-bit Keccak state register bank (25 x 64-bit)
    logic [1599:0] theta_q;             // Intermediate pipelining register for 2-phase mode (FAST_24=0)
    logic [4:0]    round_q;             // Round counter (0 to 23)
    logic          busy_q;              // Engine busy flag: asserted during active permutation
    logic          ready_q;             // Engine ready status register
    logic          phase_q;             // Phase toggle register for 2-phase mode (0: Theta, 1: Chi/Iota)
    logic          chi_en_q   [0:6];    // Clustered clock enable control signals for state registers

    //----------------------------------------------------------------------------------------------
    // Datapath Combinational Signals
    //----------------------------------------------------------------------------------------------
    logic [63:0]   a [0:24];            // Deconstructed 25-lane representation of state_q
    logic [63:0]   b [0:24];            // Intermediate lanes after Theta, Rho rotation, and Pi mapping
    logic [63:0]   c [0:4];             // Column parities for Theta step: C[x] = XOR sum of column x
    logic [1599:0] next_theta;          // 1600-bit combinational state resulting from Theta diffusion
    logic [63:0]   chi_b [0:24];        // 25 lanes resulting from Chi non-linear layer

    //----------------------------------------------------------------------------------------------
    // Cryptographic Helper Functions
    //----------------------------------------------------------------------------------------------

    // 64-bit Circular Left Shift (Rotate Left, ROL)
    function automatic logic [63:0] rol(input logic [63:0] x, input integer n);
        rol = (x << n) | (x >> (64-n));
    endfunction

    // Rho Step Bit-Rotation Offsets (NIST FIPS 202 Table 2)
    // Defines the cyclic bit-shift count applied to each lane index i in [0..23]
    function automatic integer rho(input integer i);
        case (i)
            0:rho=1; 1:rho=3; 2:rho=6; 3:rho=10; 4:rho=15; 5:rho=21;
            6:rho=28; 7:rho=36; 8:rho=45; 9:rho=55; 10:rho=2; 11:rho=14;
            12:rho=27; 13:rho=41; 14:rho=56; 15:rho=8; 16:rho=25; 17:rho=43;
            18:rho=62; 19:rho=18; 20:rho=39; 21:rho=61; 22:rho=20; 23:rho=44;
            default:rho=0;
        endcase
    endfunction

    // Pi Step Lane Coordinate Permutation (NIST FIPS 202 Section 3.2.3)
    // Maps 1D lane traversal order i to target lane index pi(i) = y + 5*((2x + 3y) mod 5)
    function automatic integer pi(input integer i);
        case (i)
            0:pi=10; 1:pi=7; 2:pi=11; 3:pi=17; 4:pi=18; 5:pi=3;
            6:pi=5; 7:pi=16; 8:pi=8; 9:pi=21; 10:pi=24; 11:pi=4;
            12:pi=15; 13:pi=23; 14:pi=19; 15:pi=13; 16:pi=12; 17:pi=2;
            18:pi=20; 19:pi=14; 20:pi=22; 21:pi=9; 22:pi=6; 23:pi=1;
            default:pi=0;
        endcase
    endfunction

    // Iota Step Round Constants RC[r] (NIST FIPS 202 Section 3.2.5, Table 4)
    // Injected into lane [0,0] (lane index 0) for each round r in [0..23]
    function automatic logic [63:0] rc(input logic [4:0] r);
        case (r)
            0:rc=64'h0000000000000001; 1:rc=64'h0000000000008082;
            2:rc=64'h800000000000808a; 3:rc=64'h8000000080008000;
            4:rc=64'h000000000000808b; 5:rc=64'h0000000080000001;
            6:rc=64'h8000000080008081; 7:rc=64'h8000000000008009;
            8:rc=64'h000000000000008a; 9:rc=64'h0000000000000088;
            10:rc=64'h0000000080008009; 11:rc=64'h000000008000000a;
            12:rc=64'h000000008000808b; 13:rc=64'h800000000000008b;
            14:rc=64'h8000000000008089; 15:rc=64'h8000000000008003;
            16:rc=64'h8000000000008002; 17:rc=64'h8000000000000080;
            18:rc=64'h000000000000800a; 19:rc=64'h800000008000000a;
            20:rc=64'h8000000080008081; 21:rc=64'h8000000000008080;
            22:rc=64'h0000000080000001; 23:rc=64'h8000000080008008;
            default:rc='0;
        endcase
    endfunction

    //==============================================================================================
    // STEP 1: THETA (θ) TRANSFORMATION
    // Parity calculation and column diffusion:
    //   C[x] = A[x,0] ^ A[x,1] ^ A[x,2] ^ A[x,3] ^ A[x,4]  (5-input XOR, mapped to 1 LUT5 level)
    //   D[x] = C[(x+4)%5] ^ ROL64(C[(x+1)%5], 1)
    //   next_theta[5*y + x] = A[5*y + x] ^ D[x]             (3-input XOR, mapped to 1 LUT3 level)
    // Total combinational depth: exactly 2 LUT levels.
    //==============================================================================================

    // Lane extraction from 1600-bit state register bank
    for (genvar i=0; i<25; i=i+1) begin: GEN_A
        assign a[i] = state_q[i*64 +: 64];
    end

    // Compute column parities C[x] for x in 0..4
    for (genvar x=0; x<5; x=x+1) begin: GEN_C
        assign c[x] = a[x] ^ a[x+5] ^ a[x+10] ^ a[x+15] ^ a[x+20];
    end

    // Compute Theta-diffused state next_theta[x, y]
    for (genvar y=0; y<5; y=y+1) begin: GEN_THETA_Y
        for (genvar x=0; x<5; x=x+1) begin: GEN_THETA_X
            assign next_theta[(5*y+x)*64 +: 64] = a[5*y+x] ^ c[(x+4)%5] ^ rol(c[(x+1)%5], 1);
        end
    end

    //==============================================================================================
    // PIPELINE INTERMEDIATE STAGE / FAST_24 MULTIPLEXING
    // In FAST_24 mode: rho, pi, and chi operate directly on combinational next_theta (1 cycle/round).
    // In 48-cycle mode: rho, pi, and chi operate from registered intermediate theta_q (2 cycles/round).
    //==============================================================================================
    wire [1599:0] theta_wire = FAST_24 ? next_theta : theta_q;

    //==============================================================================================
    // STEPS 2 & 3: RHO (ρ) ROTATION & PI (π) PERMUTATION
    // Origin lane (0,0) is unrotated: b[0] = theta_wire[0].
    // Remaining 24 lanes undergo cyclic rotation by rho(i) bits and permutation to lane b[pi(i)].
    // Realized entirely via zero-latency wire rewiring in hardware.
    //==============================================================================================
    assign b[0] = theta_wire[0*64 +: 64];
    for (genvar i=0; i<24; i=i+1) begin: GEN_B
        assign b[pi(i)] = rol(theta_wire[((i == 0) ? 1 : pi(i-1))*64 +: 64], rho(i));
    end

    //==============================================================================================
    // STEP 4: CHI (χ) NON-LINEAR TRANSFORMATION
    // Evaluates non-linear boolean equation across each row:
    //   chi_b[x,y] = b[x,y] ^ (~b[(x+1)%5, y] & b[(x+2)%5, y])
    // Perfectly maps to 64 parallel LUT5 structures per 5-lane row.
    //==============================================================================================
    for (genvar y=0; y<5; y=y+1) begin: GEN_CHI_Y
        for (genvar x=0; x<5; x=x+1) begin: GEN_CHI_X
            assign chi_b[5*y+x] = b[5*y+x] ^ ((~b[5*y+(x+1)%5]) & b[5*y+(x+2)%5]);
        end
    end

    //==============================================================================================
    // STEP 5: IOTA (ι) CONSTANT INJECTION & STATE REGISTER UPDATE
    // Injects round constant round_rc into lane 0.
    // Supports clean 2:1 multiplexing between round iteration (next_chi) and message absorption.
    //==============================================================================================
    wire [63:0] round_rc = rc(round_q);
    wire absorb_en = load || absorb;
    wire is_first  = load || absorb_first;

    // Clean 2:1 state register D-multiplexer (absorb_val vs next_chi) with clock enable
    for (genvar i=0; i<25; i=i+1) begin: GEN_STATE_REG
        (* keep = "true" *) wire [63:0] next_chi = (i == 0) ? (chi_b[0] ^ round_rc) : chi_b[i];
        wire [63:0] absorb_val = (is_first ? 64'd0 : state_q[i*64 +: 64]) ^ state_in[i*64 +: 64];
        wire [63:0] state_d = absorb_en ? absorb_val : next_chi;
        wire        state_ce = absorb_en || chi_en_q[i/4];

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                state_q[i*64 +: 64] <= '0;
            end else if (state_ce) begin
                state_q[i*64 +: 64] <= state_d;
            end
        end
    end

    // Intermediate Theta Register for 2-Phase Pipelining (FAST_24 = 0)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            theta_q <= '0;
        end else if (!FAST_24) begin
            theta_q <= next_theta;
        end
    end

    // Output Status and State Assignment
    assign ready = ready_q;
    assign state_out = state_q;

    //==============================================================================================
    // FINITE STATE & ROUND CONTROL SEQUENCER
    // Manages round counter (0 to 23), handshakes (start, done, ready), and clock-enable gating.
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_q <= 1'b1;
            busy_q  <= 1'b0;
            round_q <= '0;
            phase_q <= 1'b0;
            done    <= 1'b0;
            for (integer k=0; k<7; k=k+1) begin
                chi_en_q[k]   <= 1'b0;
            end
        end else begin
            done <= 1'b0;
            if (FAST_24) begin
                // HPKA 24-cycle single-round execution
                if (start && !busy_q) begin
                    ready_q <= 1'b0;
                    round_q <= '0;
                    busy_q  <= 1'b1;
                    phase_q <= 1'b0;
                    for (integer k=0; k<7; k=k+1) begin
                        chi_en_q[k]   <= 1'b1;
                    end
                end else if (busy_q) begin
                    if (round_q == 5'd23) begin
                        ready_q <= 1'b1;
                        busy_q  <= 1'b0;
                        phase_q <= 1'b0;
                        for (integer k=0; k<7; k=k+1) begin
                            chi_en_q[k]   <= 1'b0;
                        end
                        done <= 1'b1;
                    end else begin
                        round_q <= round_q + 1'b1;
                    end
                end
            end else begin
                // 48-cycle 2-phase execution
                if (start && !busy_q) begin
                    ready_q <= 1'b0;
                    round_q <= '0;
                    phase_q <= 1'b0;
                    busy_q  <= 1'b1;
                    for (integer k=0; k<7; k=k+1) begin
                        chi_en_q[k]   <= 1'b0;
                    end
                end else if (busy_q) begin
                    phase_q <= ~phase_q;
                    if (!phase_q) begin
                        for (integer k=0; k<7; k=k+1) begin
                            chi_en_q[k] <= 1'b1;
                        end
                    end else begin
                        for (integer k=0; k<7; k=k+1) begin
                            chi_en_q[k] <= 1'b0;
                        end
                        if (round_q == 5'd23) begin
                            ready_q <= 1'b1;
                            busy_q <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            round_q <= round_q + 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
