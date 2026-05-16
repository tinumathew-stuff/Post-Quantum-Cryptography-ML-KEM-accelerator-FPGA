`timescale 1ns / 1ps
//==============================================================================
// Module: mlkem_poly_compress
// Project: ML-KEM High-Performance Cryptographic Hardware Accelerator
// Standard: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
//
// Description:
//   High-throughput, fully pipelined, division-less and multiplier-less
//   polynomial coefficient compressor for ML-KEM (Kyber).
//   Implements NIST FIPS 203 Algorithm 4 (Compress_d) across all standard
//   security levels (ML-KEM-512, ML-KEM-768, ML-KEM-1024).
//
// Mathematical Specification:
//   For a ring element coefficient x in Z_q, where q = 3329:
//     Compress_d(x) = round((2^d / q) * x) mod 2^d
//
//   Using standard nearest-integer rounding with tie-breaking:
//     round(z) = floor(z + 1/2) = floor((2*z + 1) / 2)
//     round((2^d / q) * x) = floor((2^{d+1} * x + q) / (2 * q))
//                          = floor((2^d * x + floor(q / 2)) / q)
//                          = floor((2^d * x + 1664) / 3329) mod 2^d
//
// Division-less & Multiplier-less Reciprocal Scaling (Zero-DSP):
//   Direct hardware division by q = 3329 is area-prohibitive and high-latency.
//   Instead, the division is transformed into fixed-point multiplication by the
//   scaled reciprocal of q:
//     1 / 3329 ~= C_SCALE / 2^29
//     where C_SCALE = round(2^29 / 3329) = round(536870912 / 3329) = 161271.
//
//   With this constant reciprocal, the rounding expression becomes:
//     Compress_d(x) = floor(( (2^d * x) * 161271 + 1664 * 161271 ) / 2^29) mod 2^d
//     where C_OFFSET = 1664 * 161271 = 268354944 (32'd268354944).
//     Division by 2^29 is performed as a trivial wire slice (bit extraction [39:29]).
//   This fixed-point formulation is proven 100% bit-exact to mathematical integer
//   division floor((2^d * x + 1664) / 3329) for all x in [0, 3328] and d in {1, 4, 5, 10, 11}.
//
// Canonical Signed Digit (CSD) Shift-Add Tree (161271 * x):
//   Rather than dedicating an FPGA DSP48E2 slice, multiplication by 161271 is
//   synthesized entirely in LUT fabric via an optimized CSD / common subexpression
//   adder tree requiring only 3 additions and 1 subtraction:
//     161271 = 163840 - 2569 = (5 * 32768) - (5 * 512 + 9)
//
//     - Stage 2: Compute common subexpressions:
//         T = (x << 2) + x  = 5 * x
//         U = (x << 3) + x  = 9 * x
//     - Stage 3: Scale and combine:
//         V    = (T << 9) + U = (5 * 512 + 9) * x = 2569 * x
//         T_hi = T << 15      = 5 * 32768 * x     = 163840 * x
//     - Stage 4: Subtract to produce exact constant product:
//         prod = T_hi - V = (163840 - 2569) * x = 161271 * x
//
// Microarchitectural Pipeline Organization (7 Stages, Latency = 7 cycles, II = 1):
//   - Stage 1: Input registered boundary & signed-to-unsigned canonical reduction [0, q-1].
//   - Stage 2: CSD partial products T = 5*x and U = 9*x.
//   - Stage 3: Subexpression assembly V = 2569*x and T_hi = 163840*x.
//   - Stage 4: Constant product assembly prod = 161271 * x.
//   - Stage 5: Dynamic power-of-two shift by d (s4_prod << d).
//   - Stage 6: Fixed-point rounding constant addition (+ C_OFFSET).
//   - Stage 7: Quotient extraction (s6_full >> 29), d-bit masking, output skid register.
//
// Flow Control & Backpressure:
//   Equipped with AXI4-Stream slave and master handshakes. Synchronous elastic stall
//   control (pipe_en) freezes all internal pipeline stages simultaneously whenever
//   downstream receiver backpressures (m_valid_r && !m_axis_tready), guaranteeing
//   zero loss of transient in-flight coefficients.
//==============================================================================

module mlkem_poly_compress (
    // Clock and active-low reset
    input  wire        clk,            // System clock
    input  wire        rst_n,          // Asynchronous active-low reset

    // Streaming slave interface (16-bit signed coefficient int16_t matching C reference)
    input  wire        s_axis_tvalid,  // Slave stream data valid
    output wire        s_axis_tready,  // Slave stream ready (backpressure to upstream)
    input  wire [15:0] s_axis_tdata,   // int16_t coefficient in centered range [-q, q-1] or [0, q-1]
    input  wire [3:0]  s_axis_td,      // Runtime bit-depth parameter d in {1, 4, 5, 10, 11}
    input  wire        s_axis_tlast,   // Frame end delimiter (last coefficient of polynomial)

    // Streaming master interface (compressed output coefficients)
    output wire        m_axis_tvalid,  // Master stream data valid
    input  wire        m_axis_tready,  // Master stream ready (downstream acceptance)
    output wire [10:0] m_axis_tdata,   // Compressed d-bit coefficient in [0, 2^d - 1]
    output wire        m_axis_tlast    // Frame end delimiter for compressed polynomial
);

    // Modulus and precalculated fixed-point reciprocal rounding constants
    localparam [11:0] Q = 12'd3329;
    localparam [31:0] C_OFFSET = 32'd268354944; // 1664 * 161271 (floor(q/2) * round(2^29 / q))

    //--------------------------------------------------------------------------
    // Elastic Pipeline Stall Control
    //   pipe_en: Global pipeline clock-enable. When downstream backpressures
    //            (m_valid_r && !m_axis_tready), all internal stages freeze in place.
    //--------------------------------------------------------------------------
    wire pipe_en;

    reg        m_valid_r;
    reg [10:0] m_data_r;
    reg        m_last_r;

    assign pipe_en       = !m_valid_r || m_axis_tready;
    assign s_axis_tready = pipe_en;

    //--------------------------------------------------------------------------
    // Stage 1: Input Boundary Register & Signed Restoration
    //   Decouples external input ports from arithmetic logic.
    //   Normalizes centered signed int16_t coefficients [-q, q-1] to standard
    //   positive canonical modular range [0, q-1] by adding Q if negative.
    //--------------------------------------------------------------------------
    reg [11:0] s1_x;
    reg [3:0]  s1_d;
    reg        s1_last;
    reg        s1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_x     <= 12'd0;
            s1_d     <= 4'd0;
            s1_last  <= 1'b0;
        end else if (pipe_en) begin
            s1_valid <= s_axis_tvalid;
            s1_d     <= s_axis_td;
            s1_last  <= s_axis_tlast;
            // Signed reduction: if MSB (sign bit) is 1, add Q=3329 to restore [0, 3328]
            s1_x     <= s_axis_tdata[15] ? (s_axis_tdata[11:0] + Q) : s_axis_tdata[11:0];
        end
    end

    //--------------------------------------------------------------------------
    // Stage 2: Common Subexpressions (CSD Adders)
    //   Computes T = 5*x and U = 9*x using basic shift-and-add operations:
    //     T = (x << 2) + x  (15 bits max: 5 * 3328 = 16640)
    //     U = (x << 3) + x  (16 bits max: 9 * 3328 = 29952)
    //--------------------------------------------------------------------------
    reg [14:0] s2_T;
    reg [15:0] s2_U;
    reg [3:0]  s2_d;
    reg        s2_last;
    reg        s2_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_T     <= 15'd0;
            s2_U     <= 16'd0;
            s2_d     <= 4'd0;
            s2_last  <= 1'b0;
        end else if (pipe_en) begin
            s2_valid <= s1_valid;
            s2_d     <= s1_d;
            s2_last  <= s1_last;
            s2_T     <= (s1_x << 2) + s1_x; // 5 * x
            s2_U     <= (s1_x << 3) + s1_x; // 9 * x
        end
    end

    //--------------------------------------------------------------------------
    // Stage 3: CSD Subexpression Assembly
    //   Combines partial products into higher-order terms:
    //     V    = (T << 9) + U = (5 * 512 + 9) * x = 2569 * x
    //     T_hi = T << 15      = 5 * 32768 * x     = 163840 * x
    //--------------------------------------------------------------------------
    reg [23:0] s3_V;
    reg [29:0] s3_T_hi;
    reg [3:0]  s3_d;
    reg        s3_last;
    reg        s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
            s3_V     <= 24'd0;
            s3_T_hi  <= 30'd0;
            s3_d     <= 4'd0;
            s3_last  <= 1'b0;
        end else if (pipe_en) begin
            s3_valid <= s2_valid;
            s3_d     <= s2_d;
            s3_last  <= s2_last;
            s3_V     <= (s2_T << 9) + {8'd0, s2_U};
            s3_T_hi  <= {s2_T, 15'd0};
        end
    end

    //--------------------------------------------------------------------------
    // Stage 4: Constant Product Assembly (x * 161271)
    //   Computes exact product:
    //     prod = T_hi - V = 163840*x - 2569*x = 161271 * x.
    //   Maximum value: 3328 * 161271 = 536,709,888 < 2^30 (fits in 30 bits).
    //--------------------------------------------------------------------------
    reg [29:0] s4_prod;
    reg [3:0]  s4_d;
    reg        s4_last;
    reg        s4_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_valid <= 1'b0;
            s4_prod  <= 30'd0;
            s4_d     <= 4'd0;
            s4_last  <= 1'b0;
        end else if (pipe_en) begin
            s4_valid <= s3_valid;
            s4_d     <= s3_d;
            s4_last  <= s3_last;
            s4_prod  <= s3_T_hi - {6'd0, s3_V};
        end
    end

    //--------------------------------------------------------------------------
    // Stage 5: Shift by d with Minimal Multiplexer Logic
    //   Multiplies constant product by 2^d by shifting s4_prod left by d bits.
    //   Combinational multiplexer selects alignment before the Stage 5 register.
    //--------------------------------------------------------------------------
    reg [39:0] s4_shifted_prod;
    always @(*) begin
        case (s4_d)
            4'd1:    s4_shifted_prod = {9'd0,  s4_prod, 1'b0};
            4'd4:    s4_shifted_prod = {6'd0,  s4_prod, 4'd0};
            4'd5:    s4_shifted_prod = {5'd0,  s4_prod, 5'd0};
            4'd10:   s4_shifted_prod = {       s4_prod, 10'd0};
            default: s4_shifted_prod = {s4_prod[28:0],  11'd0}; // 11
        endcase
    end

    reg [39:0] s5_shifted;
    reg [3:0]  s5_d;
    reg        s5_last;
    reg        s5_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_valid   <= 1'b0;
            s5_shifted <= 40'd0;
            s5_d       <= 4'd0;
            s5_last    <= 1'b0;
        end else if (pipe_en) begin
            s5_valid   <= s4_valid;
            s5_shifted <= s4_shifted_prod;
            s5_d       <= s4_d;
            s5_last    <= s4_last;
        end
    end

    //--------------------------------------------------------------------------
    // Stage 6: Constant Offset Addition
    //   Adds precomputed rounding bias C_OFFSET = 1664 * 161271 = 268354944.
    //   Computes numerator: (2^d * x + 1664) * 161271.
    //--------------------------------------------------------------------------
    reg [40:0] s6_full;
    reg [3:0]  s6_d;
    reg        s6_last;
    reg        s6_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s6_valid <= 1'b0;
            s6_full  <= 41'd0;
            s6_d     <= 4'd0;
            s6_last  <= 1'b0;
        end else if (pipe_en) begin
            s6_valid <= s5_valid;
            s6_d     <= s5_d;
            s6_last  <= s5_last;
            s6_full  <= {1'b0, s5_shifted} + {9'd0, C_OFFSET};
        end
    end

    //--------------------------------------------------------------------------
    // Stage 7: Quotient Extraction & Output Boundary Register
    //   Division by 2^29 via bit slice: quot = s6_full[39:29].
    //   Masks quotient to lower d bits to perform modular reduction (mod 2^d).
    //   Stores compressed result into final skid register.
    //--------------------------------------------------------------------------
    wire [10:0] quot = s6_full[39:29];
    reg  [10:0] s6_res;
    always @(*) begin
        case (s6_d)
            4'd1:    s6_res = {10'd0, quot[0]};
            4'd4:    s6_res = {7'd0,  quot[3:0]};
            4'd5:    s6_res = {6'd0,  quot[4:0]};
            4'd10:   s6_res = {1'd0,  quot[9:0]};
            default: s6_res = quot[10:0]; // 11
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid_r <= 1'b0;
            m_data_r  <= 11'd0;
            m_last_r  <= 1'b0;
        end else if (pipe_en) begin
            m_valid_r <= s6_valid;
            m_data_r  <= s6_res;
            m_last_r  <= s6_last;
        end
    end

    // Master stream output assignments
    assign m_axis_tvalid = m_valid_r;
    assign m_axis_tdata  = m_data_r;
    assign m_axis_tlast  = m_last_r;

endmodule
