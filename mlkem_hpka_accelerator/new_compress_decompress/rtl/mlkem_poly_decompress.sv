`timescale 1ns / 1ps
//==============================================================================
// Module: mlkem_poly_decompress
// Project: ML-KEM High-Performance Cryptographic Hardware Accelerator
// Standard: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
//
// Description:
//   High-throughput, fully pipelined polynomial coefficient decompressor
//   implementing NIST FIPS 203 Algorithm 5 (Decompress_d).
//   Restores compressed d-bit coefficients back into 12-bit ring elements in
//   Z_q where q = 3329 across all supported security parameters:
//     - ML-KEM-512  (d_u = 10, d_v = 4)
//     - ML-KEM-768  (d_u = 10, d_v = 5)
//     - ML-KEM-1024 (d_u = 11, d_v = 5)
//     - Plaintext / Encrypt message decompression (d = 1)
//
// Mathematical Specification:
//   For an ingested d-bit value y in {0, ..., 2^d - 1}:
//     Decompress_d(y) = round((q / 2^d) * y)
//
//   Applying standard nearest-integer rounding (round-half-up):
//     round(z) = floor(z + 1/2) = floor((2*z + 1) / 2)
//     round((q / 2^d) * y) = floor((2 * (q / 2^d) * y + 1) / 2)
//                          = floor((2*q*y + 2^d) / (2 * 2^d))
//                          = floor((q * y + 2^{d-1}) / 2^d)
//                          = (3329 * y + 2^{d-1}) >> d
//
//   The additive rounding term is exactly 2^{d-1}:
//     - d = 1:  round = 2^0  = 1
//     - d = 4:  round = 2^3  = 8
//     - d = 5:  round = 2^4  = 16
//     - d = 10: round = 2^9  = 512
//     - d = 11: round = 2^10 = 1024
//
// Zero-DSP Shift-Add Arithmetic Decomposition:
//   Modulus q = 3329 is factored into power-of-two components:
//     3329 = 3072 + 257 = (3 * 1024) + (256 + 1) = (3 * 2^10) + (2^8 + 1)
//
//   Hardware multiplication (3329 * y + 2^{d-1}) is executed entirely without
//   dedicated DSP multipliers using balanced adder tree stages:
//     - Stage 2: Concurrent calculation of partial products:
//         term1 = (y << 1) + y = 3 * y
//         term2 = (y << 8) + y = 257 * y
//     - Stage 3: Rounding bias accumulation:
//         term2_round = term2 + 2^{d-1} = 257 * y + 2^{d-1}
//     - Stage 4: Sum assembly:
//         sum = (term1 << 10) + term2_round
//             = 3072 * y + 257 * y + 2^{d-1} = 3329 * y + 2^{d-1}
//     - Stage 5: Division by 2^d via static right-shift wire slices (sum >> d).
//
// Pipeline Timing & Throughput:
//   - Latency: 5 clock cycles from s_axis_tdata to m_axis_tdata.
//   - Initiation Interval (II): 1 cycle (sustained 1 coefficient/cycle throughput).
//   - Elastic Handshaking: Synchronous stall network freezes all stages upon downstream
//     backpressure, preventing pipeline bubbles and preserving data integrity.
//==============================================================================

module mlkem_poly_decompress (
    // Clock and active-low reset
    input  wire        clk,            // System clock
    input  wire        rst_n,          // Asynchronous active-low reset

    // Streaming slave interface (compressed input coefficients)
    input  wire        s_axis_tvalid,  // Slave data valid
    output wire        s_axis_tready,  // Slave ready (backpressure to upstream producer)
    input  wire [10:0] s_axis_tdata,   // Compressed input y in [0, 2^d - 1]
    input  wire [3:0]  s_axis_td,      // Runtime bit-depth parameter d in {1, 4, 5, 10, 11}
    input  wire        s_axis_tlast,   // Frame delimiter for last coefficient of polynomial

    // Streaming master interface (decompressed output coefficients in [0, 3328])
    output wire        m_axis_tvalid,  // Master data valid
    input  wire        m_axis_tready,  // Master ready (downstream acceptance)
    output wire [11:0] m_axis_tdata,   // Decompressed 12-bit coefficient in [0, q-1]
    output wire        m_axis_tlast    // Frame delimiter for decompressed polynomial
);

    // Modulus constant
    localparam [11:0] Q = 12'd3329;

    //--------------------------------------------------------------------------
    // Common Elastic Enable
    //   Freezes data and valid registers simultaneously whenever the downstream
    //   master interface is stalled (!m_axis_tready with valid output pending).
    //--------------------------------------------------------------------------
    wire pipe_en;

    reg        m_valid_r;
    reg [11:0] m_data_r;
    reg        m_last_r;

    assign pipe_en       = !m_valid_r || m_axis_tready;
    assign s_axis_tready = pipe_en;

    //--------------------------------------------------------------------------
    // Stage 1: Registered Input Capture & Round Constant Generation
    //   Decouples module inputs from downstream arithmetic stages.
    //   Generates exact rounding constant 2^{d-1} based on runtime parameter d.
    //--------------------------------------------------------------------------
    reg [10:0] s1_data;
    reg [10:0] s1_round;
    reg [3:0]  s1_d;
    reg        s1_last;
    reg        s1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
            s1_data  <= 11'd0;
            s1_round <= 11'd0;
            s1_d     <= 4'd0;
            s1_last  <= 1'b0;
        end else if (pipe_en) begin
            s1_valid <= s_axis_tvalid;
            s1_data  <= s_axis_tdata;
            s1_d     <= s_axis_td;
            s1_last  <= s_axis_tlast;
            // Rounding bias: 2^(d-1) for nearest-integer rounding
            case (s_axis_td)
                4'd1:    s1_round <= 11'd1;    // 2^0
                4'd4:    s1_round <= 11'd8;    // 2^3
                4'd5:    s1_round <= 11'd16;   // 2^4
                4'd10:   s1_round <= 11'd512;  // 2^9
                default: s1_round <= 11'd1024; // 2^10 (for d=11)
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Stage 2: Balanced CSD Partial Products: 3*y (13b) and 257*y (20b)
    //   Decomposes modulus 3329 = 3 * 1024 + 257:
    //     s2_term1 = 3 * y   = (y << 1) + y
    //     s2_term2 = 257 * y = (y << 8) + y  (max: 257 * 2047 = 526,079)
    //--------------------------------------------------------------------------
    reg [12:0] s2_term1;
    reg [19:0] s2_term2;
    reg [10:0] s2_round;
    reg [3:0]  s2_d;
    reg        s2_last;
    reg        s2_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid <= 1'b0;
            s2_term1 <= 13'd0;
            s2_term2 <= 20'd0;
            s2_round <= 11'd0;
            s2_d     <= 4'd0;
            s2_last  <= 1'b0;
        end else if (pipe_en) begin
            s2_valid <= s1_valid;
            s2_term1 <= {1'b0, s1_data, 1'b0} + {2'b0, s1_data};    // 3 * y
            s2_term2 <= {1'b0, s1_data, 8'd0} + {9'd0, s1_data};    // 257 * y (max 526079)
            s2_round <= s1_round;
            s2_d     <= s1_d;
            s2_last  <= s1_last;
        end
    end

    //--------------------------------------------------------------------------
    // Stage 3: Balanced Partial Sum with Rounding Offset
    //   Adds precomputed rounding offset to 257*y:
    //     s3_term2_round = (257 * y) + 2^{d-1}
    //   Pipeline register buffers s3_term1 in parallel for stage 4 assembly.
    //--------------------------------------------------------------------------
    reg [12:0] s3_term1;
    reg [19:0] s3_term2_round;
    reg [3:0]  s3_d;
    reg        s3_last;
    reg        s3_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid       <= 1'b0;
            s3_term1       <= 13'd0;
            s3_term2_round <= 20'd0;
            s3_d           <= 4'd0;
            s3_last        <= 1'b0;
        end else if (pipe_en) begin
            s3_valid       <= s2_valid;
            s3_term1       <= s2_term1;
            s3_term2_round <= s2_term2 + {9'd0, s2_round};
            s3_d           <= s2_d;
            s3_last        <= s2_last;
        end
    end

    //--------------------------------------------------------------------------
    // Stage 4: Balanced Sum Assembly
    //   Combines terms to produce exact rounded dividend:
    //     s4_sum = (3 * y << 10) + (257 * y + 2^{d-1})
    //            = 3072 * y + 257 * y + 2^{d-1}
    //            = 3329 * y + 2^{d-1}
    //   Maximum value: 3329 * 2047 + 1024 = 6,815,487 < 2^24.
    //--------------------------------------------------------------------------
    reg [23:0] s4_sum;
    reg [3:0]  s4_d;
    reg        s4_last;
    reg        s4_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_valid <= 1'b0;
            s4_sum   <= 24'd0;
            s4_d     <= 4'd0;
            s4_last  <= 1'b0;
        end else if (pipe_en) begin
            s4_valid <= s3_valid;
            s4_sum   <= {1'b0, s3_term1, 10'd0} + {4'd0, s3_term2_round};
            s4_d     <= s3_d;
            s4_last  <= s3_last;
        end
    end

    //--------------------------------------------------------------------------
    // Stage 5: Targeted Extraction & Shift by d into Output Boundary Register
    //   Performs division by 2^d by selecting bit range [11+d : d].
    //   Guaranteed in range [0, 3328] matching canonical Z_q ring elements.
    //--------------------------------------------------------------------------
    reg [11:0] s4_res;
    always @(*) begin
        case (s4_d)
            4'd1:    s4_res = s4_sum[12:1];   // Shift right by 1
            4'd4:    s4_res = s4_sum[15:4];   // Shift right by 4
            4'd5:    s4_res = s4_sum[16:5];   // Shift right by 5
            4'd10:   s4_res = s4_sum[21:10];  // Shift right by 10
            default: s4_res = s4_sum[22:11];  // Shift right by 11 (d=11)
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_valid_r <= 1'b0;
            m_data_r  <= 12'd0;
            m_last_r  <= 1'b0;
        end else if (pipe_en) begin
            m_valid_r <= s4_valid;
            m_data_r  <= s4_res;
            m_last_r  <= s4_last;
        end
    end

    // Master stream output assignments
    assign m_axis_tvalid = m_valid_r;
    assign m_axis_tdata  = m_data_r;
    assign m_axis_tlast  = m_last_r;

endmodule
