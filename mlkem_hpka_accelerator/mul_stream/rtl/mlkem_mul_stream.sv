`timescale 1ns/1ps

// ============================================================================
// Module: mlkem_dsp_mul
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Description:
//   Fully pipelined 4-cycle unsigned multiplier targeted to a single AMD
//   Xilinx DSP48E2 primitive. Optimized for high-frequency operation (>450 MHz)
//   on UltraScale+ architectures.
//
// DSP48E2 Pipeline Architecture:
//   - AREG = 2: Two input pipeline registers on operand A (a_r1, a_r2)
//   - BREG = 2: Two input pipeline registers on operand B (b_r1, b_r2)
//   - MREG = 1: Multiplier product pipeline register (m_r3)
//   - PREG = 1: Dedicated P-output cascade register (p_r4)
//
// Latency: Exactly 4 clock cycles from inputs {a, b} to output p.
// Resource Cost: 1 x DSP48E2 slice, 0 LUTs, 0 FFs outside the DSP block.
// ============================================================================
(* use_dsp = "yes" *)
module mlkem_dsp_mul #(
    parameter int WIDTH_A = 12,  // Bit width of multiplicand operand A
    parameter int WIDTH_B = 12,  // Bit width of multiplicand operand B
    parameter int WIDTH_P = 24   // Bit width of resulting product P (WIDTH_A + WIDTH_B)
)(
    input  logic               clk, // System clock (nominally 450 MHz)
    input  logic [WIDTH_A-1:0] a,   // Operand A input
    input  logic [WIDTH_B-1:0] b,   // Operand B input
    output logic [WIDTH_P-1:0] p    // Registered product output: p = a * b (latency = 4 cc)
);
    // Pipeline stage registers matching DSP48E2 internal architectural registers
    logic [WIDTH_A-1:0] a_r1, a_r2; // Maps to AREG1, AREG2 inside DSP48E2
    logic [WIDTH_B-1:0] b_r1, b_r2; // Maps to BREG1, BREG2 inside DSP48E2
    logic [WIDTH_P-1:0] m_r3;       // Maps to MREG (multiplier output register)
    logic [WIDTH_P-1:0] p_r4;       // Maps to PREG (post-adder/accumulator output register)

    // Synchronous 4-stage pipeline propagation
    always_ff @(posedge clk) begin
        // Pipeline Stage 1: Input sampling (AREG1 / BREG1)
        a_r1 <= a;
        b_r1 <= b;
        // Pipeline Stage 2: Secondary input register (AREG2 / BREG2)
        a_r2 <= a_r1;
        b_r2 <= b_r1;
        // Pipeline Stage 3: Multiplier core evaluation (MREG)
        m_r3 <= a_r2 * b_r2;
        // Pipeline Stage 4: Output register stage (PREG)
        p_r4 <= m_r3;
    end

    // Direct continuous assignment from output stage register
    assign p = p_r4;
endmodule


// ============================================================================
// Module: mlkem_reduce25
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Description:
//   Fully pipelined 5-cycle Barrett-style modular reduction for ML-KEM / Kyber
//   prime modulus q = 3329.
//
// Mathematical Background:
//   Given an unsigned dividend x in range [0, 2^25 - 1] (i.e. x < 33,554,432):
//   We seek the canonical residue r = x mod 3329 in range [0, 3328].
//
//   1. Quotient Estimation via Fixed-Point Multiplication:
//      We approximate the reciprocal 1/3329 ≈ 315 / 2^20:
//        315 / 2^20 = 315 / 1048576 ≈ 0.0003004074097...
//        1 / 3329                 ≈ 0.0003003905077...
//      The relative error is positive and bounded by:
//        delta = (315/2^20) - (1/3329) ≈ 1.6902e-8.
//      For all x < 2^25:
//        x * delta < (2^25) * 1.6902e-8 ≈ 0.5671 < 1.0.
//      Consequently, qhat = floor(x * 315 / 2^20) satisfies:
//        floor(x / 3329) <= qhat <= floor(x / 3329) + 1.
//      That is, qhat either equals the exact integer quotient or overestimates
//      it by at most 1. Crucially, it NEVER underestimates!
//
//   2. Multiplierless Scale by 315:
//      315 * x is synthesized with minimal LUT adder trees (0 DSPs):
//        times63  = (x << 6) - x          = 63 * x  (1 subtractor)
//        times315 = (times63 << 2) + times63 = 5 * times63 = 315 * x (1 adder)
//      Quotient estimate: qhat = times315[32:20].
//
//   3. Modulo 2^13 Remainder Evaluation:
//      Since q = 3329 = 3328 + 1 = 13 * 256 + 1, computing qhat * 3329 mod 2^13:
//        qhat * 3329 = qhat * (13 * 256 + 1) = qhat + (13 * qhat) * 2^8.
//      Taking mod 2^13 (8192), terms with 2^13 vanish:
//        ((13 * qhat) * 2^8) mod 2^13 = (((13 * qhat) mod 2^5) << 8).
//      Since (13 * qhat) mod 32 depends strictly on qhat[4:0], it is evaluated
//      via a 32-entry LUT: low13[j] = (13 * j) % 32.
//      Thus: qmul = qhat + {low13[qhat[4:0]], 8'b0} (mod 2^13).
//
//   4. Conditional Overestimate Correction:
//      rem = (xd[2] - qmul) mod 2^13 (signed 13-bit representation).
//      If qhat was exact: rem = x % 3329 in [0, 3328], rem[12] == 0 (positive).
//      If qhat overestimated by 1: rem = (x % 3329) - 3329 in [-3329, -1],
//      which sets rem[12] == 1 (negative).
//      Correction: r = rem[12] ? (rem + 3329) : rem.
//
// Latency: 5 clock cycles.
// Resource Cost: Pure LUT/FF logic; 0 DSP48E2 slices.
// ============================================================================
module mlkem_reduce25 (
    input  logic        clk, // System clock
    input  logic [24:0] x,   // 25-bit unreduced input operand (0 <= x < 2^25)
    output logic [11:0] r    // 12-bit canonical modular residue in [0, 3328]
);
    // Intermediate pipeline registers
    logic [30:0] times63;           // Stage 1: x * 63 = (x << 6) - x
    logic [32:0] times315;          // Stage 2: times63 * 5 = (times63 << 2) + times63
    logic [12:0] xd [0:2];          // 3-stage delay shift-register for lower 13 bits of x
    wire  [12:0] qhat = times315[32:20]; // Truncated quotient estimate floor(315 * x / 2^20)
    logic [12:0] qmul;              // Stage 3: (qhat * 3329) mod 2^13
    logic signed [12:0] rem;        // Stage 4: Signed remainder (x - qhat*3329) mod 2^13
    logic [4:0] low13 [0:31];       // Precomputed ROM: (13 * j) mod 32 for j in [0, 31]

    // Precompute the 32-entry LUT during elaboration/initialization
    initial for (integer j=0;j<32;j=j+1) low13[j]=(13*j)%32;

    // 5-stage synchronous reduction pipeline
    always_ff @(posedge clk) begin
        // Pipeline Stage 1: Multiplication by 63 and input register capture
        times63  <= {x, 6'b0} - x;
        xd[0]    <= x[12:0];

        // Pipeline Stage 2: Multiplication by 5 to obtain times315 = x * 315
        times315 <= {times63, 2'b0} + times63;
        xd[1]    <= xd[0];

        // Pipeline Stage 3: Low 13-bit reconstruction of (qhat * 3329)
        xd[2]    <= xd[1];
        qmul     <= qhat + {low13[qhat[4:0]], 8'b0};

        // Pipeline Stage 4: Signed remainder subtraction
        rem      <= $signed(xd[2] - qmul);

        // Pipeline Stage 5: Final conditional addition of modulus 3329
        r        <= rem[12] ? rem + 13'd3329 : rem;
    end
endmodule


// ============================================================================
// Module: mlkem_mul_stream
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Description:
//   Streaming Dual-Channel Pointwise Polynomial Multiplier and Accumulator
//   designed for the Number Theoretic Transform (NTT) domain operations of
//   ML-KEM (FIPS 203) across security parameter sets k = 2, 3, 4 (ML-KEM-512,
//   ML-KEM-768, ML-KEM-1024).
//
// Mathematical Ring Formulation:
//   In ML-KEM, polynomials of degree 256 over Z_q[X]/(X^256 + 1) are transformed
//   via NTT into 128 degree-1 polynomial factors over:
//     R_q = Z_q[X] / (X^2 - zeta^(2r+1)),  for r in [0, 127], q = 3329.
//
//   Each degree-1 polynomial is represented as a coefficient pair (f_2j, f_2j+1):
//     f(X) = f_0 + f_1 * X.
//   Given two degree-1 polynomials a(X) = a_0 + a_1*X and b(X) = b_0 + b_1*X:
//     c(X) = a(X) * b(X) mod (X^2 - zeta)
//          = (a_0*b_0 + a_1*b_1*zeta) + (a_0*b_1 + a_1*b_0)*X.
//
// Karatsuba Multiplication Architecture (4 DSPs per Channel):
//   Rather than computing 4 separate multiplications, Karatsuba degree-1
//   formulation uses 3 primary multiplications plus 1 twiddle reduction:
//     1. M0    = a_0 * b_0
//     2. M1    = a_1 * b_1
//     3. Msum  = (a_0 + a_1) * (b_0 + b_1)
//     4. Cross = Msum - M0 - M1 = a_0*b_1 + a_1*b_0  (Linear coefficient)
//     5. r11   = Barrett_Reduce(M1)
//     6. Mz    = r11 * zeta                          (Twiddle product)
//     7. c_0   = Barrett_Reduce(M0 + Mz)             (Constant coefficient)
//     8. c_1   = Barrett_Reduce(Cross)               (Linear coefficient)
//
// Dual-Channel Throughput:
//   Two identical pointwise multiplier channels operate in parallel:
//     - Channel 0 (PWM0): Computes pair 2j   (coefficients 0, 1) using zeta0.
//     - Channel 1 (PWM1): Computes pair 2j+1 (coefficients 2, 3) using zeta1.
//   Throughput: 4 coefficients (2 degree-1 polynomials) per clock cycle.
//   An entire 256-coefficient polynomial multiplication completes in 64 clock cycles.
//
// DSP48E2 Allocation (Strictly 8 DSPs Total):
//   - PWM0: u_m0 (DSP0), u_m1 (DSP1), u_msum0 (DSP2), u_mz0 (DSP3)
//   - PWM1: u_m2 (DSP4), u_m3 (DSP5), u_msum1 (DSP6), u_mz1 (DSP7)
//   Total: 8 x DSP48E2 primitives. Zero additional DSP slices consumed.
//
// Operating Modes (s_mode):
//   - Mode 0 (s_mode = 2'd0): Single Pair / Bypass Mode.
//       Multiplies a single coefficient pair at s_base_index.
//   - Mode 1 (s_mode = 2'd1): Polynomial Multiply Mode.
//       Streams 64 pairs (256 coefficients) without accumulation across terms.
//   - Mode 2 (s_mode = 2'd2): Vector Dot Product Mode.
//       Multiplies and accumulates across k polynomial pairs (inner product).
//   - Mode 3 (s_mode = 2'd3): Matrix-Vector Product Mode.
//       Evaluates an entire k x k matrix-vector multiplication (k rows, each of length k).
//
// Pipelining and Latency:
//   - Total Pipeline Depth (LAT): 24 clock cycles.
//   - Multiplier DSP Latency: 4 cycles.
//   - Barrett Reduction Latency: 5 cycles.
//   - Twiddle Factor Delay Line: 10 cycles matching M1 -> r11 -> Mz path.
//   - Accumulator and Centering: 4 cycles.
//
// Flow Control & Backpressure:
//   - Credit-based reservation counter prevents pipeline stalls and FIFO overruns.
//   - Distributed RAM (RAM32M) FIFO stores up to 32 output quadruple-words.
//   - Centered modular reduction [-1664, 1664] applied prior to output FIFO storage.
// ============================================================================
module mlkem_mul_stream (
    // Clock and Reset
    input  logic               clk,           // System clock (450 MHz)
    input  logic               rst,           // Synchronous active-high reset

    // AXI-Stream Style Slave Interface (Input Operand Stream)
    input  logic               s_valid,       // Valid input stream handshake
    output logic               s_ready,       // Ready credit backpressure indicator
    input  logic               s_start,       // First cycle strobe of a new computation sequence
    input  logic               s_accumulate,  // Accumulate flag (1 = enable inner product accumulation)
    input  logic [1:0]         s_mode,        // Operation mode: 0=single pair, 1=poly mul, 2=dot prod, 3=matrix-vector
    input  logic [2:0]         s_k,           // Vector/Matrix dimension k in [2, 3, 4]
    input  logic [5:0]         s_base_index,  // Starting pair index (used in mode 0)
    input  logic signed [12:0] s_a0, s_a1,    // PWM0 Operand A (Pair 2j: coeff 0, coeff 1)
    input  logic signed [12:0] s_b0, s_b1,    // PWM0 Operand B (Pair 2j: coeff 0, coeff 1)
    input  logic signed [12:0] s_a2, s_a3,    // PWM1 Operand A (Pair 2j+1: coeff 2, coeff 3)
    input  logic signed [12:0] s_b2, s_b3,    // PWM1 Operand B (Pair 2j+1: coeff 2, coeff 3)

    // AXI-Stream Style Master Interface (Output Result Stream)
    output logic               m_valid,       // Valid output stream indicator
    input  logic               m_ready,       // Downstream receiver ready signal
    output logic signed [11:0] m_c0, m_c1,    // PWM0 Result (Pair 2j: coeff 0, coeff 1) in [-1664, 1664]
    output logic signed [11:0] m_c2, m_c3,    // PWM1 Result (Pair 2j+1: coeff 2, coeff 3) in [-1664, 1664]
    output logic [5:0]         m_index,       // Coefficient pair index (0 to 63)
    output logic [1:0]         m_row,         // Matrix row index (0 to k-1)
    output logic               m_last         // End of full matrix/vector computation sequence
);
    // Pipeline latency parameter: exactly 24 clock cycles
    localparam integer LAT = 24;

    // FSM State and Sequence Tracking Registers
    logic [1:0] mode;            // Latched operation mode
    logic [1:0] term;            // Current inner-product polynomial term index [0 .. k-1]
    logic [1:0] row;             // Current matrix row index [0 .. k-1]
    logic [2:0] kval;            // Latched dimension parameter k
    logic [5:0] idx;             // Current pair index [0 .. 63] (128 pairs total / 2 channels = 64 steps)
    logic       is_final_term_q; // Registered lookahead: active on last term of inner product
    logic       is_final_pair_q; // Registered lookahead: active on last coefficient pair (idx == 63)
    logic       is_final_row_q;  // Registered lookahead: active on last row of matrix multiplication

    // Multiplexed instantaneous sequence values based on s_start strobe
    wire [1:0] imode = s_start ? s_mode : mode;
    wire [2:0] ik    = s_start ? (((s_mode < 2) && !s_accumulate) ? 3'd1 : s_k) : kval;
    wire [1:0] iterm = s_start ? 2'd0 : term;
    wire [1:0] irow  = s_start ? 2'd0 : row;
    wire [5:0] iidx  = s_start ? ((s_mode == 0) ? s_base_index : 6'd0) : idx;

    // Boundary condition detection wires
    wire start_final_term = (ik == 3'd1);
    wire start_final_pair = (s_mode == 2'd0) || (((s_mode == 2'd0) ? s_base_index : 6'd0) == 6'd63);
    wire start_final_row  = (s_mode != 2'd3) || (ik == 3'd1);

    wire final_term = s_start ? start_final_term : is_final_term_q;
    wire final_pair = s_start ? start_final_pair : is_final_pair_q;
    wire final_row  = s_start ? start_final_row  : is_final_row_q;

    // Credit-based Flow Control Logic:
    // Tracks pipeline occupancy and FIFO slots. Up to 32 entries can be in-flight.
    logic [5:0] reserved;
    wire take = s_valid && s_ready; // Input handshake successfully fired
    wire pop  = m_valid && m_ready; // Output handshake successfully fired
    assign s_ready = !reserved[5];  // Deassert ready when 32 items are reserved (bit 5 high)

    // Pipeline delay lines for sideband control signals
    logic [LAT-1:0] valid_pipe; // Propagation of data valid flag through 24 stages
    logic [LAT-1:0] first_pipe; // Indicates first term of an accumulation sequence (clears accumulator)
    logic [LAT-1:0] end_pipe;   // Indicates final term of an accumulation sequence (triggers FIFO push)
    logic [LAT-1:0] last_pipe;  // Indicates very last item of the overall matrix/vector operation

    // Pipeline delay line for metadata tags {row[1:0], idx[5:0]} implemented as SRL16E/SRL32E
    (* srl_style = "srl" *) logic [7:0] tag_pipe [0:LAT-1];

    // =========================================================================
    // NTT Zeta Twiddle Factors Table
    // Implemented as 12 bit-planes of 128-bit truth tables.
    // Maps directly to 6-input LUTs (LUT6) as bounded combinational functions
    // without consuming Block RAMs or UltraRAMs.
    // =========================================================================
    localparam logic [127:0] ZETA [0:11] = '{
        128'h966a999aa555659a659959559a59a555,
        128'hcf33fff0f30f330c0003c30ff00c0c30,
        128'hb5ee55afa2f5edf833fe71f99f04cb10,
        128'h69a5aaaaa2a65aa411a96e6a66c84aec,
        128'h95955999ad56a557216a5566a9b8b66b,
        128'h55a565a9556555952ea95555656499aa,
        128'h569a55a5aa5a6596296a6a5655545556,
        128'haaa59a999a5aa656e9999659595b96a6,
        128'h3c30c030300c0f303cff3f00f0030000,
        128'h14137023ecf8ca13eba9e5ff530e0ffc,
        128'h827709440201e07b000033cf08936302,
        128'h658896a9599a1644a656481056949866
    };

    logic [5:0]  zidx_q;                  // Registered twiddle index
    logic [11:0] zeta0_reg, zeta1_reg;    // Registered twiddle values for PWM0 and PWM1
    (* srl_style = "srl" *) logic [11:0] zpipe0 [0:7]; // 8-stage SRL delay for PWM0 twiddle
    (* srl_style = "srl" *) logic [11:0] zpipe1 [0:7]; // 8-stage SRL delay for PWM1 twiddle

    // Combinational bit-plane slicing for dual twiddles:
    // zeta0 corresponds to {zidx_q, 1'b0} (even index = 2j)
    // zeta1 corresponds to {zidx_q, 1'b1} (odd index  = 2j+1)
    wire [11:0] zeta0_comb, zeta1_comb;
    for (genvar bitnum=0;bitnum<12;bitnum=bitnum+1) begin: GEN_ZETA
        assign zeta0_comb[bitnum] = ZETA[bitnum][{zidx_q, 1'b0}];
        assign zeta1_comb[bitnum] = ZETA[bitnum][{zidx_q, 1'b1}];
    end

    integer i;

    // Sequential Control Logic: FSM Counters, Reservation Bookkeeping, and Twiddle Pipeline
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset state registers
            mode            <= 0;
            kval            <= 1;
            term            <= 0;
            row             <= 0;
            idx             <= 0;
            is_final_term_q <= 1'b1;
            is_final_pair_q <= 1'b1;
            is_final_row_q  <= 1'b1;
            valid_pipe      <= 0;
            first_pipe      <= 0;
            end_pipe        <= 0;
            last_pipe       <= 0;
            reserved        <= 0;
            zidx_q          <= 6'd0;
            zeta0_reg       <= 12'd0;
            zeta1_reg       <= 12'd0;
            for (i=0; i<8; i=i+1) begin
                zpipe0[i] <= 12'd0;
                zpipe1[i] <= 12'd0;
            end
            for (i=0; i<LAT; i=i+1) begin
                tag_pipe[i] <= 8'd0;
            end
        end else begin
            // Advance sideband pipeline shift registers
            valid_pipe <= {valid_pipe[LAT-2:0], take};
            first_pipe <= {first_pipe[LAT-2:0], take ? (iterm == 0) : 1'b0};
            end_pipe   <= {end_pipe[LAT-2:0],   take ? final_term : 1'b0};
            last_pipe  <= {last_pipe[LAT-2:0],  take ? (final_term && final_pair && final_row) : 1'b0};

            // Reservation credit management: increment on valid stream intake, decrement on output pop
            case ({take && final_term, pop})
                2'b10:   reserved <= reserved + 1'b1;
                2'b01:   reserved <= reserved - 1'b1;
                default: reserved <= reserved;
            endcase

            // Advance iteration indices on handshake intake
            if (take) begin
                mode <= imode;
                kval <= ik;
                term <= final_term ? 2'd0 : iterm + 1'b1;
                idx  <= final_term ? (final_pair ? 6'd0 : iidx + 1'b1) : iidx;
                row  <= final_term && final_pair ? irow + 1'b1 : irow;

                // Precompute boundary flags for subsequent clock cycles
                is_final_term_q <= ({1'b0, (final_term ? 2'd0 : iterm + 1'b1)} == ik - 3'd1);
                is_final_pair_q <= (imode == 2'd0) || ((final_term ? (final_pair ? 6'd0 : iidx + 1'b1) : iidx) == 6'd63);
                is_final_row_q  <= (imode != 2'd3) || ({1'b0, (final_term && final_pair ? irow + 1'b1 : irow)} == ik - 3'd1);
            end

            // 10-cycle twiddle factor pipeline matching the M1 -> ur11 -> Mz delay path:
            // Stage 1 (cc 1): Register input pair index iidx
            zidx_q    <= iidx;
            // Stage 2 (cc 2): Register zeta bitplane table lookup
            zeta0_reg <= zeta0_comb;
            zeta1_reg <= zeta1_comb;
            // Stages 3..10 (cc 3..10): 8-stage SRL pipeline delay
            zpipe0[0] <= zeta0_reg;
            zpipe1[0] <= zeta1_reg;
            for (i=1; i<8; i=i+1) begin
                zpipe0[i] <= zpipe0[i-1];
                zpipe1[i] <= zpipe1[i-1];
            end

            // Shift metadata tag pipeline only when valid intake occurs
            tag_pipe[0] <= take ? {irow, iidx} : 8'd0;
            for (i=1; i<LAT; i=i+1) begin
                tag_pipe[i] <= tag_pipe[i-1];
            end
        end
    end

    // Input normalization helper function:
    // Maps signed 13-bit representation in [-3328, 3328] to canonical unsigned 12-bit [0, 3328]
    function automatic logic [11:0] norm13(input logic signed [12:0] val);
        logic signed [13:0] ext;
        ext = val[12] ? ($signed(val) + 14'sd3329) : $signed({1'b0, val[11:0]});
        return ext[11:0];
    endfunction

    // Input operand pipeline registers for Channel 0 (PWM0) and Channel 1 (PWM1)
    logic [11:0] a0, a1, b0, b1; // Channel 0 normalized inputs
    logic [11:0] a2, a3, b2, b3; // Channel 1 normalized inputs
    always_ff @(posedge clk) begin
        a0 <= norm13(s_a0);
        a1 <= norm13(s_a1);
        b0 <= norm13(s_b0);
        b1 <= norm13(s_b1);
        a2 <= norm13(s_a2);
        a3 <= norm13(s_a3);
        b2 <= norm13(s_b2);
        b3 <= norm13(s_b3);
    end

    // =========================================================================
    // CHANNEL 0: PWM0 Arithmetic (Pair 2j: Coefficients 0 and 1)
    // Karatsuba Multiplication utilizing 4 dedicated DSP48E2 slices:
    //   DSP0: M0    = a0 * b0                (12x12 -> 24-bit)
    //   DSP1: M1    = a1 * b1                (12x12 -> 24-bit)
    //   DSP2: Msum0 = (a0 + a1) * (b0 + b1)  (13x13 -> 26-bit)
    //   Sub:  Cross = Msum0 - M0 - M1        (cross0_raw)
    //   DSP3: Mz0   = r11 * zeta0            (12x12 -> 24-bit)
    // =========================================================================
    wire [12:0] sum_a01 = {1'b0, a0} + {1'b0, a1}; // Pre-adder for Karatsuba sum
    wire [12:0] sum_b01 = {1'b0, b0} + {1'b0, b1}; // Pre-adder for Karatsuba sum

    logic [23:0] m0, m1;
    logic [25:0] msum0;
    logic [23:0] mz0;

    // DSP 0: Constant term product a0 * b0
    mlkem_dsp_mul #(.WIDTH_A(12), .WIDTH_B(12), .WIDTH_P(24)) u_m0 (
        .clk(clk), .a(a0), .b(b0), .p(m0)
    );

    // DSP 1: Linear term product a1 * b1
    mlkem_dsp_mul #(.WIDTH_A(12), .WIDTH_B(12), .WIDTH_P(24)) u_m1 (
        .clk(clk), .a(a1), .b(b1), .p(m1)
    );

    // DSP 2: Combined sum product (a0 + a1) * (b0 + b1)
    mlkem_dsp_mul #(.WIDTH_A(13), .WIDTH_B(13), .WIDTH_P(26)) u_msum0 (
        .clk(clk), .a(sum_a01), .b(sum_b01), .p(msum0)
    );

    // Reconstruct cross term: a0*b1 + a1*b0 = Msum0 - M0 - M1
    wire [25:0] cross0_raw = msum0 - {2'b00, m0} - {2'b00, m1};

    // Barrett reduction of M1 to mod 3329 prior to twiddle factor multiplication
    logic [11:0] r11;
    mlkem_reduce25 ur11 (
        .clk(clk), .x({1'b0, m1}), .r(r11)
    );

    // DSP 3: Twiddle product Mz0 = (M1 mod q) * zeta0
    mlkem_dsp_mul #(.WIDTH_A(12), .WIDTH_B(12), .WIDTH_P(24)) u_mz0 (
        .clk(clk), .a(r11), .b(zpipe0[7]), .p(mz0)
    );

    // 9-cycle SRL delay matching M0 and cross0 with the arrival of mz0
    (* srl_style = "srl" *) logic [23:0] p00_delay [0:8];
    (* srl_style = "srl" *) logic [24:0] cross_delay0 [0:8];
    always_ff @(posedge clk) begin
        p00_delay[0]    <= m0;
        cross_delay0[0] <= cross0_raw[24:0];
        for (integer j=1; j<9; j=j+1) begin
            p00_delay[j]    <= p00_delay[j-1];
            cross_delay0[j] <= cross_delay0[j-1];
        end
    end

    // Summation of constant term and registration of linear cross term
    logic [24:0] sum0, sum1;
    always_ff @(posedge clk) begin
        sum0 <= {1'b0, p00_delay[8]} + {1'b0, mz0}; // Constant term: M0 + (M1 * zeta0)
        sum1 <= cross_delay0[8];                     // Linear term: Cross
    end

    // Final modular reduction to canonical [0, 3328] for Channel 0
    logic [11:0] r0, r1;
    mlkem_reduce25 ur0 (.clk(clk), .x(sum0), .r(r0));
    mlkem_reduce25 ur1 (.clk(clk), .x(sum1), .r(r1));

    // =========================================================================
    // CHANNEL 1: PWM1 Arithmetic (Pair 2j+1: Coefficients 2 and 3)
    // Karatsuba Multiplication utilizing 4 dedicated DSP48E2 slices:
    //   DSP4: M2    = a2 * b2                (12x12 -> 24-bit)
    //   DSP5: M3    = a3 * b3                (12x12 -> 24-bit)
    //   DSP6: Msum1 = (a2 + a3) * (b2 + b3)  (13x13 -> 26-bit)
    //   Sub:  Cross = Msum1 - M2 - M3        (cross1_raw)
    //   DSP7: Mz1   = r33 * zeta1            (12x12 -> 24-bit)
    // =========================================================================
    wire [12:0] sum_a23 = {1'b0, a2} + {1'b0, a3}; // Pre-adder for Karatsuba sum
    wire [12:0] sum_b23 = {1'b0, b2} + {1'b0, b3}; // Pre-adder for Karatsuba sum

    logic [23:0] m2, m3;
    logic [25:0] msum1;
    logic [23:0] mz1;

    // DSP 4: Constant term product a2 * b2
    mlkem_dsp_mul #(.WIDTH_A(12), .WIDTH_B(12), .WIDTH_P(24)) u_m2 (
        .clk(clk), .a(a2), .b(b2), .p(m2)
    );

    // DSP 5: Linear term product a3 * b3
    mlkem_dsp_mul #(.WIDTH_A(12), .WIDTH_B(12), .WIDTH_P(24)) u_m3 (
        .clk(clk), .a(a3), .b(b3), .p(m3)
    );

    // DSP 6: Combined sum product (a2 + a3) * (b2 + b3)
    mlkem_dsp_mul #(.WIDTH_A(13), .WIDTH_B(13), .WIDTH_P(26)) u_msum1 (
        .clk(clk), .a(sum_a23), .b(sum_b23), .p(msum1)
    );

    // Reconstruct cross term: a2*b3 + a3*b2 = Msum1 - M2 - M3
    wire [25:0] cross1_raw = msum1 - {2'b00, m2} - {2'b00, m3};

    // Barrett reduction of M3 to mod 3329 prior to twiddle factor multiplication
    logic [11:0] r33;
    mlkem_reduce25 ur33 (
        .clk(clk), .x({1'b0, m3}), .r(r33)
    );

    // DSP 7: Twiddle product Mz1 = (M3 mod q) * zeta1
    mlkem_dsp_mul #(.WIDTH_A(12), .WIDTH_B(12), .WIDTH_P(24)) u_mz1 (
        .clk(clk), .a(r33), .b(zpipe1[7]), .p(mz1)
    );

    // 9-cycle SRL delay matching M2 and cross1 with the arrival of mz1
    (* srl_style = "srl" *) logic [23:0] p22_delay [0:8];
    (* srl_style = "srl" *) logic [24:0] cross_delay1 [0:8];
    always_ff @(posedge clk) begin
        p22_delay[0]    <= m2;
        cross_delay1[0] <= cross1_raw[24:0];
        for (integer j=1; j<9; j=j+1) begin
            p22_delay[j]    <= p22_delay[j-1];
            cross_delay1[j] <= cross_delay1[j-1];
        end
    end

    // Summation of constant term and registration of linear cross term
    logic [24:0] sum2, sum3;
    always_ff @(posedge clk) begin
        sum2 <= {1'b0, p22_delay[8]} + {1'b0, mz1}; // Constant term: M2 + (M3 * zeta1)
        sum3 <= cross_delay1[8];                     // Linear term: Cross
    end

    // Final modular reduction to canonical [0, 3328] for Channel 1
    logic [11:0] r2, r3;
    mlkem_reduce25 ur2 (.clk(clk), .x(sum2), .r(r2));
    mlkem_reduce25 ur3 (.clk(clk), .x(sum3), .r(r3));

    // =========================================================================
    // Accumulation & Centered Modular Normalization Pipeline
    // Performs inner-product accumulation across k vector/matrix elements,
    // followed by range reduction into centered interval [-1664, 1664].
    // =========================================================================
    logic [13:0] acc0, acc1, acc2, acc3;                 // Running accumulator registers
    logic [13:0] norm0, norm1, norm2, norm3;             // Stage 1 modulo fold: subtract 2*q (6658) if needed
    logic [12:0] norm20, norm21, norm22, norm23;         // Stage 2 modulo fold: subtract q (3329) if needed
    logic signed [11:0] center0, center1, center2, center3; // Stage 3 centering: convert to [-1664, 1664]

    // Accumulator clear on first_pipe[19], otherwise add incoming reduced residues
    wire [13:0] next0 = (first_pipe[19] ? 14'd0 : acc0) + r0;
    wire [13:0] next1 = (first_pipe[19] ? 14'd0 : acc1) + r1;
    wire [13:0] next2 = (first_pipe[19] ? 14'd0 : acc2) + r2;
    wire [13:0] next3 = (first_pipe[19] ? 14'd0 : acc3) + r3;

    always_ff @(posedge clk) begin
        // Accumulator Stage (Cycle 20): Update accumulator when valid pipeline token arrives
        if (valid_pipe[19]) begin
            acc0 <= next0;
            acc1 <= next1;
            acc2 <= next2;
            acc3 <= next3;
        end

        // Modular Fold Stage 1 (Cycle 21): Reduce ranges [0, 3*3328] down by 2*3329 = 6658
        norm0 <= acc0 >= 6658 ? acc0 - 14'd6658 : acc0;
        norm1 <= acc1 >= 6658 ? acc1 - 14'd6658 : acc1;
        norm2 <= acc2 >= 6658 ? acc2 - 14'd6658 : acc2;
        norm3 <= acc3 >= 6658 ? acc3 - 14'd6658 : acc3;

        // Modular Fold Stage 2 (Cycle 22): Reduce range down by 3329 to ensure [0, 3328]
        norm20 <= norm0 >= 3329 ? norm0 - 14'd3329 : norm0;
        norm21 <= norm1 >= 3329 ? norm1 - 14'd3329 : norm1;
        norm22 <= norm2 >= 3329 ? norm2 - 14'd3329 : norm2;
        norm23 <= norm3 >= 3329 ? norm3 - 14'd3329 : norm3;

        // Centering Stage (Cycle 23): Map [0, 3328] to symmetric signed interval [-1664, +1664]
        center0 <= norm20 > 1664 ? norm20 - 13'd3329 : norm20;
        center1 <= norm21 > 1664 ? norm21 - 13'd3329 : norm21;
        center2 <= norm22 > 1664 ? norm22 - 13'd3329 : norm22;
        center3 <= norm23 > 1664 ? norm23 - 13'd3329 : norm23;
    end

    // =========================================================================
    // Output Stream FIFO (Cycle 24)
    // 32-entry distributed RAM FIFO (RAM32M) decoupling the 24-cycle pipeline
    // from downstream AXI-Stream handshaking.
    // Word packing format: {m_last, m_row[1:0], m_index[5:0], c3, c2, c1, c0}
    // =========================================================================
    (* ram_style = "distributed" *) logic [56:0] fifo [0:31];
    logic [4:0] rdptr, wrptr; // 5-bit circular write and read pointers
    logic [5:0] stored;       // Occupancy counter tracking elements in FIFO

    // Push into FIFO when pipeline token reaches Stage 24 and represents the final term
    wire push = valid_pipe[LAT-1] && end_pipe[LAT-1];

    // Master interface flow signals
    assign m_valid = (stored != 0);
    assign {m_last, m_row, m_index, m_c3, m_c2, m_c1, m_c0} = fifo[rdptr];

    // Synchronous distributed RAM write
    always_ff @(posedge clk) begin
        if (push) begin
            fifo[wrptr] <= {last_pipe[LAT-1], tag_pipe[LAT-1], center3, center2, center1, center0};
        end
    end

    // FIFO Pointer and State Management
    always_ff @(posedge clk) begin
        if (rst) begin
            rdptr  <= 0;
            wrptr  <= 0;
            stored <= 0;
        end else begin
            if (push) wrptr <= wrptr + 1'b1;
            if (pop)  rdptr <= rdptr + 1'b1;
            case ({push, pop})
                2'b10:   stored <= stored + 1'b1; // Enqueue without dequeue
                2'b01:   stored <= stored - 1'b1; // Dequeue without enqueue
                default: stored <= stored;        // Simultaneous push/pop or idle
            endcase
        end
    end
endmodule
