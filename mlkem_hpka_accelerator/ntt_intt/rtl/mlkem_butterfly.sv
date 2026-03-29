//==============================================================================
// File: mlkem_butterfly.sv
// Project: ML-KEM (CRYSTALS-Kyber) High-Performance Hardware Accelerator
// Component: Pipelined Zero-DSP Unified NTT/INTT Butterfly ALU
//
// Description:
//   Fully pipelined, high-throughput, strictly zero-DSP Butterfly Arithmetic
//   Logic Unit (ALU) supporting both Cooley-Tukey Decimation-in-Time (DIT)
//   for the forward Number Theoretic Transform (NTT) and Gentleman-Sande
//   Decimation-in-Frequency (DIF) for the inverse transform (INTT), as well as
//   monadic coefficient normalization.
//
// Performance & Target Technology:
//   - Target Clock Frequency: 450 MHz on AMD UltraScale+ (xck26-sfvc784-2LV-c).
//   - Fixed Pipeline Latency: 10 clock cycles (fully pipelined, 1 butterfly/cycle).
//   - Zero DSP Resource Footprint: Enforced by (* use_dsp = "no" *) to preserve
//     valuable DSP slices (DSP48E2) for Keccak / matrix operations elsewhere.
//   - Shift Register Logic (SRL): Delay balancing bypass paths mapped to
//     dedicated SRL16E / SRLC32E primitives via (* srl_style = "srl" *).
//
// Mathematical Foundations:
//   Operates over the prime field GF(q) with modulus q = 3329 = 13 * 2^8 + 1.
//   Operands a, b, zeta are in canonical residue form [0, q-1] = [0, 3328].
//
//   1. Forward NTT (inverse = 0, normalize = 0) - Cooley-Tukey DIT Butterfly:
//      - Computes:
//          result_a = (a + b * zeta) mod q
//          result_b = (a - b * zeta) mod q
//      - Multiplicand x = b, Multiplier w = zeta.
//      - The addend 'a' is buffered through a 7-stage delay line (bypass_q).
//      - Stage 9 performs butterfly combine; Stage 10 guarantees canonical range.
//
//   2. Inverse INTT (inverse = 1, normalize = 0) - Gentleman-Sande DIF Butterfly:
//      - Computes:
//          result_a = (a + b) mod q
//          result_b = ((a - b) * zeta) mod q
//        (where zeta loaded from ROM is the negated root: -zeta^(-k) mod q).
//      - Stage 2 computes sub_pos = (a - b) mod q; Multiplicand x = sub_pos, w = zeta.
//      - The sum (a + b) mod q is buffered through the 7-stage delay line (bypass_q).
//      - Stage 9 routes bypass_q to result_a and modular product p_q to result_b.
//
//   3. Normalization Mode (normalize = 1):
//      - Computes scaling of single coefficient: result_a = result_b = (a * zeta) mod q.
//      - Multiplicand x = a, Multiplier w = zeta (e.g., zeta = 128^(-1) = 3303 mod q).
//      - Product p_q is broadcast to both output registers.
//
// Soft Multiplier Tree Architecture (3-Chunk 12x4, Stages 3..5):
//   To close timing at 450 MHz without DSP blocks, the 12x12 modular multiplier
//   is split into three parallel 12x4-bit sub-multipliers:
//     w = w[3:0] + (w[7:4] << 4) + (w[11:8] << 8)
//     - Stage 3: p0 = x * w[3:0],  p1 = x * w[7:4],  p2 = x * w[11:8]
//     - Stage 4: s01 = p0 + (p1 << 4), p2 delayed as p2_d
//     - Stage 5: prod = s01 + (p2_d << 8) = x * w (24-bit exact product)
//
// Zero-DSP Barrett Modular Reduction Algorithm (q = 3329, Stages 6..8):
//   1. Quotient Estimation:
//      Approximates q_hat = floor(prod / q) using the constant 315 / 2^20:
//        315 / 2^20 = (63 * 5) / 2^20 = ((64 - 1) * (4 + 1)) / 2^20
//        - Stage 6: times63 = (prod << 6) - prod
//        - Stage 7: times315 = (times63 << 2) + times63
//        - Wire   : qhat = times315[31:20] = floor(prod * 315 / 2^20)
//
//   2. Modulo 2^13 Subtraction via Special Modulus Structure (q = 13 * 256 + 1):
//      Because prod < q^2 < 2^24, the reduced remainder prod - q_hat * 3329 < q.
//      Evaluating modulo 2^13:
//        q_hat * 3329 = q_hat * (13 * 256 + 1) = q_hat + (13 * q_hat) * 256
//      Modulo 2^13, the high term ((13 * q_hat) * 256) mod 2^13 depends ONLY on
//      (13 * q_hat[4:0]) mod 32, which is precomputed in a 32x5 ROM table (low13).
//        qmul = q_hat + (low13[q_hat[4:0]] << 8)
//        rem  = (prod[12:0] - qmul) mod 2^13
//
//   3. Remainder Correction (Stage 8):
//      - If rem < 0: add q (3329) to restore canonical range.
//      - Yields exact, canonical remainder p = prod mod 3329 in [0, 3328].
//
// Pipeline Timing Summary (10 Stages):
//   +-------+-----------------------------------------------------------------+
//   | Stage | Description & Key Operations                                    |
//   +-------+-----------------------------------------------------------------+
//   |   1   | Input registration: capture a, b, zeta, inverse, normalize      |
//   |   2   | Input muxing (x_q, w_q), bypass registration (bypass_q[0])       |
//   |   3   | Multiplier Tree: three parallel 12x4 soft multiplies (p0, p1, p2)|
//   |   4   | Multiplier Tree: adder stage 1 (s01 = p0 + (p1 << 4))           |
//   |   5   | Multiplier Tree: adder stage 2 (prod = s01 + (p2_d << 8))        |
//   |   6   | Barrett Reduction: times63 = prod * 63; delay prod[12:0]        |
//   |   7   | Barrett Reduction: times315 = times63 * 5; delay xd[1]          |
//   |   8   | Barrett Reduction: remainder computation & conditional +3329    |
//   |   9   | Butterfly combine: add_q / sub_q generation                     |
//   |  10   | Output reduction: reduce_once(add_q) and canonical sub_q       |
//   +-------+-----------------------------------------------------------------+
//==============================================================================

`timescale 1ns/1ps

// Canonical residues at the interface; 12-bit modular arithmetic internally.
// Pipelined for 450 MHz on AMD UltraScale+ (10-cycle latency).
// 3-chunk (12x4) soft multiplier tree + Barrett reduction modulo 3329.
// Strictly 0 DSPs.
(* use_dsp = "no" *)
module mlkem_butterfly (
    input  logic        clk,        // System clock (450 MHz nominal)
    input  logic        inverse,    // 0: Forward NTT (Cooley-Tukey), 1: Inverse INTT (Gentleman-Sande)
    input  logic        normalize,  // 1: Monadic normalization scaling mode (a * zeta)
    input  logic [11:0] a,          // Primary 12-bit input coefficient in [0, 3328]
    input  logic [11:0] b,          // Secondary 12-bit input coefficient in [0, 3328]
    input  logic [11:0] zeta,       // 12-bit twiddle factor / root of unity in [0, 3328]
    output logic [11:0] result_a,   // Upper butterfly output coefficient in [0, 3328]
    output logic [11:0] result_b    // Lower butterfly output coefficient in [0, 3328]
);

    //--------------------------------------------------------------------------
    // Pipeline Register & Signal Declarations
    //--------------------------------------------------------------------------

    // Stage 1 Registers: Input sampling
    logic [11:0] a_q, b_q, zeta_input_q;
    logic        inverse_input_q, normalize_input_q;

    // Stage 2 Registers: Multiplier input operands
    logic [11:0] x_q; // Multiplicand (b_q for NTT, sub_pos for INTT, a_q for norm)
    logic [11:0] w_q; // Multiplier (zeta_input_q)

    // Stage 3 Registers: Partial products from 12x4 soft multipliers
    (* use_dsp = "no" *) logic [15:0] p0_q, p1_q, p2_q;

    // Stage 4 Registers: First adder stage of multiplier tree
    (* use_dsp = "no" *) logic [19:0] s01_q;   // Sum of p0 and (p1 << 4)
    (* use_dsp = "no" *) logic [15:0] p2_d_q;  // Pipeline delay for p2

    // Stage 5 Registers: Final 24-bit product
    (* use_dsp = "no" *) logic [23:0] prod_q;  // Full product: x_q * w_q

    // Stage 6 & 7 Registers: Barrett quotient estimation pipeline
    (* use_dsp = "no" *) logic [29:0] times63_q;  // prod * 63 = (prod << 6) - prod
    (* use_dsp = "no" *) logic [31:0] times315_q; // times63 * 5 = (times63 << 2) + times63

    // Barrett product lower-bit delay registers (13 bits: prod_q[12:0])
    logic [12:0] xd_q [0:1];

    // Stage 8 Registers: Modular reduction result
    logic [11:0] p_q; // Reduced product: (x * w) mod 3329

    // Stage 9 Registers: Butterfly addition/subtraction combiners
    logic [12:0] add_q, sub_q;

    // Delay lines: Bypass operand delay line (mapped into LUT SRL primitives)
    (* srl_style = "srl" *) logic [12:0] bypass_q [0:6];

    // Mode tracking shift registers (delayed to align with Stage 9 combiners)
    logic [6:0] inverse_q, normalize_q;

    //--------------------------------------------------------------------------
    // Combinatorial Logic: Stage 2 Subtractor & Difference Recovery
    //--------------------------------------------------------------------------
    // Computes (a - b) mod 3329 for Gentleman-Sande INTT butterfly
    wire [12:0] sub_raw = {1'b0, a_q} - {1'b0, b_q};
    wire [11:0] sub_pos = sub_raw[12] ? (sub_raw[11:0] + 12'd3329) : sub_raw[11:0];

    //--------------------------------------------------------------------------
    // Combinatorial Logic: Barrett Modulo 3329 Quotient & Remainder Logic
    //--------------------------------------------------------------------------
    // Estimated quotient: qhat = floor(prod * 315 / 2^20)
    wire [11:0] qhat = times315_q[31:20];

    // Precomputed lookup table for (13 * i) mod 32:
    // Exploits modulus structure q = 13 * 2^8 + 1 = 3329.
    // Replaces dynamic multiplication by 3329 with a 32-entry 5-bit lookup.
    localparam logic [4:0] low13 [0:31] = '{
        5'd0,  5'd13, 5'd26, 5'd7,  5'd20, 5'd1,  5'd14, 5'd27,
        5'd8,  5'd21, 5'd2,  5'd15, 5'd28, 5'd9,  5'd22, 5'd3,
        5'd16, 5'd29, 5'd10, 5'd23, 5'd4,  5'd17, 5'd30, 5'd11,
        5'd24, 5'd5,  5'd18, 5'd31, 5'd12, 5'd25, 5'd6,  5'd19
    };

    // Reconstructed (qhat * 3329) mod 2^13:
    // qhat * 3329 = qhat + ((13 * qhat[4:0]) mod 32) << 8 (mod 2^13)
    wire [12:0] qmul = {1'b0, qhat} + {low13[qhat[4:0]], 8'b0};

    // Modulo 2^13 remainder: xd_q[1] - qmul
    wire signed [12:0] rem_wire = $signed(xd_q[1] - qmul);
    wire signed [13:0] rem_ext  = {{1{rem_wire[12]}}, rem_wire};
    wire signed [13:0] rem_corr = rem_ext + 14'sd3329; // Add modulus if remainder is negative

    //--------------------------------------------------------------------------
    // Helper Function: Single-Sub Modular Reducer
    //--------------------------------------------------------------------------
    // Reduces a 13-bit value v in [0, 2*q - 1] to canonical range [0, q-1]
    function automatic logic [11:0] reduce_once(input logic [12:0] v);
        logic [12:0] r;
        r = v - 13'd3329;
        reduce_once = r[12] ? v[11:0] : r[11:0];
    endfunction

    //--------------------------------------------------------------------------
    // 10-Stage Butterfly Pipeline Execution
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        //----------------------------------------------------------------------
        // Stage 1: Input Registration
        // Registers incoming operands and control flags to decouple routing paths.
        //----------------------------------------------------------------------
        a_q               <= a;
        b_q               <= b;
        zeta_input_q      <= zeta;
        inverse_input_q   <= inverse;
        normalize_input_q <= normalize;

        //----------------------------------------------------------------------
        // Stage 2: Input Operand Multiplexing & Bypass Path Loading
        // - Selects multiplicand x_q based on operational mode:
        //     * Normalize : x_q = a_q
        //     * INTT (DIF): x_q = (a_q - b_q) mod 3329 = sub_pos
        //     * NTT (DIT) : x_q = b_q
        // - Loads multiplier w_q = zeta.
        // - Enters bypass value into 7-stage delay line bypass_q:
        //     * INTT : bypass_q[0] = (a_q + b_q)
        //     * NTT  : bypass_q[0] = a_q
        //----------------------------------------------------------------------
        x_q <= normalize_input_q ? a_q : (inverse_input_q ? sub_pos : b_q);
        w_q <= zeta_input_q;
        bypass_q[0] <= inverse_input_q ? ({1'b0, a_q} + {1'b0, b_q}) : {1'b0, a_q};
        for (int i=1; i<7; i++) bypass_q[i] <= bypass_q[i-1];
        inverse_q   <= {inverse_q[5:0], inverse_input_q};
        normalize_q <= {normalize_q[5:0], normalize_input_q};

        //----------------------------------------------------------------------
        // Stage 3: Three 12x4 Soft Multiplications (Zero DSP)
        // Computes partial products decomposed along 4-bit nibbles of w_q.
        // Each 12x4 multiplication maps efficiently to shallow LUT/carry logic.
        //----------------------------------------------------------------------
        p0_q <= x_q * w_q[3:0];
        p1_q <= x_q * w_q[7:4];
        p2_q <= x_q * w_q[11:8];

        //----------------------------------------------------------------------
        // Stage 4: Multiplier Adder Stage 1
        // Combines lower two partial products: s01 = p0 + (p1 << 4).
        // Pipelines p2_q into p2_d_q to maintain balanced register levels.
        //----------------------------------------------------------------------
        s01_q  <= {4'b0, p0_q} + {p1_q, 4'b0};
        p2_d_q <= p2_q;

        //----------------------------------------------------------------------
        // Stage 5: Multiplier Adder Stage 2 (Final 24-bit Product)
        // Generates complete 24-bit integer product: prod_q = x_q * w_q.
        // Max value: 3328 * 3328 = 11,075,584 (< 2^24).
        //----------------------------------------------------------------------
        prod_q <= {4'b0, s01_q} + {p2_d_q, 8'b0};

        //----------------------------------------------------------------------
        // Stage 6: Barrett Reduction - Factor 63 Multiplication
        // times63 = prod_q * 63 = (prod_q << 6) - prod_q.
        // Concurrently captures lower 13 bits of prod_q into xd_q[0].
        //----------------------------------------------------------------------
        times63_q <= {prod_q, 6'b0} - prod_q;
        xd_q[0]   <= prod_q[12:0];

        //----------------------------------------------------------------------
        // Stage 7: Barrett Reduction - Factor 5 Multiplication (Factor 315 Total)
        // times315 = times63 * 5 = (times63 << 2) + times63.
        // Yields product * 315 for quotient extraction qhat = times315[31:20].
        // Advances lower 13-bit product slice into xd_q[1].
        //----------------------------------------------------------------------
        times315_q <= {times63_q, 2'b0} + times63_q;
        xd_q[1]    <= xd_q[0];

        //----------------------------------------------------------------------
        // Stage 8: Barrett Reduction - Remainder Evaluation & Correction
        // Computes canonical modular product p_q = (x * w) mod 3329.
        // Evaluates rem_wire; conditionally adds 3329 if sign bit [12] is set.
        //----------------------------------------------------------------------
        p_q <= rem_wire[12] ? rem_corr[11:0] : rem_wire[11:0];

        //----------------------------------------------------------------------
        // Stage 9: Butterfly Combiner Stage
        // Merges reduced product p_q with aligned bypass operand bypass_q[6]:
        //   * Normalize mode : add_q = p_q,           sub_q = p_q
        //   * INTT (DIF) mode: add_q = bypass_q[6],   sub_q = p_q
        //   * NTT (DIT) mode : add_q = bypass_q + p_q, sub_q = bypass_q - p_q
        //----------------------------------------------------------------------
        add_q <= normalize_q[6] ? {1'b0, p_q} : (inverse_q[6] ? bypass_q[6] : (bypass_q[6] + {1'b0, p_q}));
        sub_q <= (normalize_q[6] || inverse_q[6]) ? {1'b0, p_q} : (bypass_q[6] - {1'b0, p_q});

        //----------------------------------------------------------------------
        // Stage 10: Output Stage & Final Canonical Range Reduction
        // Reduces results to guaranteed canonical range [0, 3328]:
        //   * result_a : reduce_once(add_q) handles range [0, 2q-1] -> [0, q-1]
        //   * result_b : sub_q[12] sign check handles negative borrow by adding 3329
        //----------------------------------------------------------------------
        result_a <= reduce_once(add_q);
        result_b <= sub_q[12] ? (sub_q[11:0] + 12'd3329) : sub_q[11:0];
    end

endmodule
