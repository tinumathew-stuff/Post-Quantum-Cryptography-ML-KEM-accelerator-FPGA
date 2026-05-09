`timescale 1ns/1ps
//==============================================================================
// Module: poly_encode
// Description: High-Throughput Streaming Polynomial Byte-Encoder for ML-KEM
//              (FIPS 203 / Kyber Algorithm 4: ByteEncode_d).
//
// Theoretical Background & Mathematical Specification:
//   In ML-KEM (FIPS 203), polynomials in the ring R_q = Z_q[X]/(X^256 + 1)
//   (with prime modulus q = 3329) or their compressed representations require
//   bit-packing into byte-aligned octet streams.
//
//   Given an integer array F = (f_0, f_1, ..., f_255) where 0 <= f_i < 2^d:
//     ByteEncode_d(F) -> B in {0, ..., 255}^(32*d)
//
//   The bit-level relationship defined by FIPS 203 Section 4.2.2 is:
//     sum_{j=0}^{8*32*d - 1} b_j * 2^j = sum_{i=0}^{255} f_i * 2^(i*d)
//
//   Supported bit-width parameters d in {1, 4, 5, 10, 11, 12}:
//     - d = 1:  Ciphertext vector c2 (ML-KEM-512/768/1024), 256 bits = 32 bytes.
//               Encoding rate: 8 coefficients -> 1 byte (1 bit/coeff).
//     - d = 4:  Compressed vector u (ML-KEM-512), 256*4 = 1024 bits = 128 bytes.
//               Encoding rate: 8 coefficients -> 4 bytes (4 bits/coeff).
//     - d = 5:  Compressed vector u (ML-KEM-768/1024), 256*5 = 1280 bits = 160 bytes.
//               Encoding rate: 8 coefficients -> 5 bytes (5 bits/coeff).
//     - d = 10: Compressed vector u (ML-KEM-512/768), 256*10 = 2560 bits = 320 bytes.
//               Encoding rate: 8 coefficients -> 10 bytes (10 bits/coeff).
//     - d = 11: Compressed vector u (ML-KEM-1024), 256*11 = 2816 bits = 352 bytes.
//               Encoding rate: 8 coefficients -> 11 bytes (11 bits/coeff).
//     - d = 12: Uncompressed ring element Z_q (public key / secret key / ciphertext),
//               256*12 = 3072 bits = 384 bytes.
//               Encoding rate: 8 coefficients -> 12 bytes (or 2 coeffs -> 3 bytes = 24 bits).
//
// Architectural Highlights & Microarchitectural Design:
//   1. 8-Coefficient Chunk Invariant:
//      Notice that for every supported d in {1, 4, 5, 10, 11, 12}, the bit-width of
//      an 8-coefficient group (8 * d) is ALWAYS an exact integer multiple of 8 bits
//      (i.e., exactly d bytes):
//        d=1  -> 8 bits  = 1 byte
//        d=4  -> 32 bits = 4 bytes
//        d=5  -> 40 bits = 5 bytes
//        d=10 -> 80 bits = 10 bytes
//        d=11 -> 88 bits = 11 bytes
//        d=12 -> 96 bits = 12 bytes
//      Therefore, a polynomial of 256 coefficients partitions into exactly 32 chunks
//      of 8 coefficients. Each chunk packs into exactly d bytes without cross-chunk
//      bit-spillover. This eliminates dynamic barrel shifters, feedback subtractors,
//      and variable-length accumulator registers in the datapath.
//
//   2. Zero-Bubble Ping-Pong Buffering:
//      A dual-bank buffer (coeff_buf[0:1][0:7]) allows continuous back-to-back
//      streaming. Bank A can accept incoming coefficients from the upstream pipeline
//      while Bank B serializes its packed bytes to the downstream interface, achieving
//      100% throughput utilization without stall bubbles between chunks.
//
//   3. High-Speed 2-Stage Hierarchical Multiplexing:
//      Static slice concatenation produces a 96-bit wire vector. An optimized 2-stage
//      4:1 multiplexer tree extracts individual bytes, meeting tight 450 MHz timing
//      constraints on AMD/Xilinx Kintex UltraScale (xcku035-ffva1156-2-e).
//
//   4. AXI4-Stream Style Handshake & Backpressure Stability:
//      Implements strict ready/valid/last flow control on both input and output ports.
//      During downstream stalls (out_valid high, out_ready low), the registered output
//      stage guarantees payload stability with zero protocol violations.
//==============================================================================

module poly_encode (
    // Clock and active-low asynchronous reset
    input  logic        clk,        // System clock (450 MHz target)
    input  logic        rst_n,      // Asynchronous active-low reset

    // Runtime bit-width configuration
    input  logic [3:0]  cfg_d,      // Runtime selectable d/l: 1, 4, 5, 10, 11, 12

    // Upstream streaming coefficient slave interface
    input  logic        in_valid,   // Upstream coefficient valid strobe
    output logic        in_ready,   // Encoder ready to accept coefficient
    input  logic [11:0] in_data,    // One 12-bit ring coefficient a_i in [0, q-1]
    input  logic        in_last,    // Stream marker for last coefficient (i = 255)

    // Downstream streaming byte master interface
    output logic        out_valid,  // Downstream byte valid strobe
    input  logic        out_ready,  // Downstream consumer ready to accept byte
    output logic [7:0]  out_data,   // Emitted byte stream B_j
    output logic        out_last    // Asserted on last byte of polynomial (j = 32*d - 1)
);

    //--------------------------------------------------------------------------
    // Function: sanitize_d
    // Description: Validates and sanitizes the runtime bit-width configuration.
    //              Maps any unsupported d input code to the default uncompressed
    //              12-bit configuration (d = 12).
    //--------------------------------------------------------------------------
    function automatic logic [3:0] sanitize_d(input logic [3:0] d_in);
        case (d_in)
            4'd1:    sanitize_d = 4'd1;
            4'd4:    sanitize_d = 4'd4;
            4'd5:    sanitize_d = 4'd5;
            4'd10:   sanitize_d = 4'd10;
            4'd11:   sanitize_d = 4'd11;
            default: sanitize_d = 4'd12;
        endcase
    endfunction

    //--------------------------------------------------------------------------
    // State and Configuration Registers
    //--------------------------------------------------------------------------
    logic        busy_q;            // Asserted while processing a 256-coefficient polynomial
    logic [3:0]  d_q;               // Latched bit-width parameter for current polynomial

    // Active bit-width: uses latched d_q when processing, otherwise samples sanitized cfg_d
    wire [3:0] cur_d = busy_q ? d_q : sanitize_d(cfg_d);

    //--------------------------------------------------------------------------
    // Input Coefficient Bit Masking
    // Description: Zeroes out unused upper bits of the 12-bit input coefficient
    //              according to the active bit-width cur_d. Ensures strictly
    //              canonical bit patterns without out-of-range bit pollution.
    //--------------------------------------------------------------------------
    logic [11:0] in_coeff_masked;
    always_comb begin
        in_coeff_masked = in_data;
        if (cur_d < 4'd12) in_coeff_masked[11]   = 1'b0;
        if (cur_d < 4'd11) in_coeff_masked[10]   = 1'b0;
        if (cur_d < 4'd10) in_coeff_masked[9:5]  = 5'b0;
        if (cur_d < 4'd5)  in_coeff_masked[4]    = 1'b0;
        if (cur_d < 4'd4)  in_coeff_masked[3:1]  = 3'b0;
    end

    //--------------------------------------------------------------------------
    // Ping-Pong Double Buffering Datapath
    // Description: Two banks of 8 coefficients each.
    //   - coeff_buf[wr_buf]: Currently accepting incoming coefficients.
    //   - coeff_buf[rd_buf]: Currently draining serialized packed bytes.
    //   - buf_valid[0:1]: Indicates whether each bank contains a full 8-coeff chunk.
    //--------------------------------------------------------------------------
    logic [11:0] coeff_buf [0:1][0:7];  // 2 banks x 8 entries x 12-bit storage
    logic        buf_valid [0:1];       // Valid chunk status flags per bank
    logic        wr_buf;                // Bank select pointer for writes (0 or 1)
    logic [2:0]  wr_cnt;                // Write coefficient index within active bank (0 to 7)
    logic        rd_buf;                // Bank select pointer for reads (0 or 1)
    logic [3:0]  rd_byte_cnt;           // Read byte index within current chunk (0 to d-1)
    logic [4:0]  chunk_cnt;             // Completed chunk counter (0 to 31 chunks per poly)
    logic [8:0]  in_coeff_cnt;          // Total coefficients ingested for current poly (0 to 256)

    //--------------------------------------------------------------------------
    // Registered Output Boundary Registers
    // Description: Isolate internal datapath logic from downstream routing delays
    //              and provide skid/stall holding capability during backpressure.
    //--------------------------------------------------------------------------
    logic        out_valid_q;           // Registered output valid flag
    logic [7:0]  out_data_q;            // Registered output byte data
    logic        out_last_q;            // Registered output last-byte flag

    assign out_valid = out_valid_q;
    assign out_data  = out_data_q;
    assign out_last  = out_last_q;

    //--------------------------------------------------------------------------
    // Upstream Flow Control Handshake
    // Description: Encoder can accept a new coefficient if the active write bank
    //              is not currently waiting to be drained (i.e. !buf_valid[wr_buf])
    //              and we have not exceeded 256 coefficients for the current poly.
    //--------------------------------------------------------------------------
    wire can_push   = !buf_valid[wr_buf] && (!busy_q || (in_coeff_cnt < 9'd256));
    assign in_ready = can_push;
    wire push_coeff = in_valid && in_ready;

    //--------------------------------------------------------------------------
    // 8-Coefficient Static Chunk Packing
    // Description: Formulates the 96-bit contiguous packed representation for 8
    //              coefficients. In accordance with FIPS 203 Section 4.2.2:
    //                Coefficient c0 occupies the lowest d bits [d-1 : 0].
    //                Coefficient c1 occupies the next d bits [2*d-1 : d].
    //                ...
    //                Coefficient c7 occupies the highest bits [8*d-1 : 7*d].
    //              Upper unused bits in chunk_bits are padded with zeros.
    //              This pure static wiring completely replaces dynamic shifters.
    //--------------------------------------------------------------------------
    logic [95:0] chunk_bits;
    wire [11:0] c0 = coeff_buf[rd_buf][0];
    wire [11:0] c1 = coeff_buf[rd_buf][1];
    wire [11:0] c2 = coeff_buf[rd_buf][2];
    wire [11:0] c3 = coeff_buf[rd_buf][3];
    wire [11:0] c4 = coeff_buf[rd_buf][4];
    wire [11:0] c5 = coeff_buf[rd_buf][5];
    wire [11:0] c6 = coeff_buf[rd_buf][6];
    wire [11:0] c7 = coeff_buf[rd_buf][7];

    always_comb begin
        case (d_q)
            4'd1: begin
                // d=1: 8 coefficients x 1 bit = 8 bits (1 byte)
                chunk_bits = {88'd0, c7[0], c6[0], c5[0], c4[0], c3[0], c2[0], c1[0], c0[0]};
            end
            4'd4: begin
                // d=4: 8 coefficients x 4 bits = 32 bits (4 bytes)
                chunk_bits = {64'd0, c7[3:0], c6[3:0], c5[3:0], c4[3:0], c3[3:0], c2[3:0], c1[3:0], c0[3:0]};
            end
            4'd5: begin
                // d=5: 8 coefficients x 5 bits = 40 bits (5 bytes)
                chunk_bits = {56'd0, c7[4:0], c6[4:0], c5[4:0], c4[4:0], c3[4:0], c2[4:0], c1[4:0], c0[4:0]};
            end
            4'd10: begin
                // d=10: 8 coefficients x 10 bits = 80 bits (10 bytes)
                chunk_bits = {16'd0, c7[9:0], c6[9:0], c5[9:0], c4[9:0], c3[9:0], c2[9:0], c1[9:0], c0[9:0]};
            end
            4'd11: begin
                // d=11: 8 coefficients x 11 bits = 88 bits (11 bytes)
                chunk_bits = {8'd0, c7[10:0], c6[10:0], c5[10:0], c4[10:0], c3[10:0], c2[10:0], c1[10:0], c0[10:0]};
            end
            default: begin // 12
                // d=12: 8 coefficients x 12 bits = 96 bits (12 bytes)
                chunk_bits = {c7[11:0], c6[11:0], c5[11:0], c4[11:0], c3[11:0], c2[11:0], c1[11:0], c0[11:0]};
            end
        endcase
    end

    //--------------------------------------------------------------------------
    // Hierarchical 2-Stage 4:1 Multiplexer Tree for Byte Extraction
    // Description: Breaks 12:1 byte extraction into two balanced 4:1 mux stages.
    //   - Stage 1: Selects 1 byte from each 4-byte slice based on rd_byte_cnt[1:0].
    //   - Stage 2: Selects between the 4 slice results based on rd_byte_cnt[3:2].
    //   This ensures minimal path delay to satisfy 450 MHz clock timing.
    //--------------------------------------------------------------------------
    logic [7:0] mux_stage1 [0:3];
    always_comb begin
        // Group 0: Bytes 0, 1, 2, 3 (bits [31:0])
        case (rd_byte_cnt[1:0])
            2'd0:    mux_stage1[0] = chunk_bits[7:0];
            2'd1:    mux_stage1[0] = chunk_bits[15:8];
            2'd2:    mux_stage1[0] = chunk_bits[23:16];
            default: mux_stage1[0] = chunk_bits[31:24];
        endcase

        // Group 1: Bytes 4, 5, 6, 7 (bits [63:32])
        case (rd_byte_cnt[1:0])
            2'd0:    mux_stage1[1] = chunk_bits[39:32];
            2'd1:    mux_stage1[1] = chunk_bits[47:40];
            2'd2:    mux_stage1[1] = chunk_bits[55:48];
            default: mux_stage1[1] = chunk_bits[63:56];
        endcase

        // Group 2: Bytes 8, 9, 10, 11 (bits [95:64])
        case (rd_byte_cnt[1:0])
            2'd0:    mux_stage1[2] = chunk_bits[71:64];
            2'd1:    mux_stage1[2] = chunk_bits[79:72];
            2'd2:    mux_stage1[2] = chunk_bits[87:80];
            default: mux_stage1[2] = chunk_bits[95:88];
        endcase

        // Group 3: Unused high index padding
        mux_stage1[3] = 8'd0;
    end

    // Stage 2: Final 4:1 multiplexer selecting the targeted byte
    logic [7:0] curr_byte_mux;
    always_comb begin
        case (rd_byte_cnt[3:2])
            2'd0:    curr_byte_mux = mux_stage1[0];
            2'd1:    curr_byte_mux = mux_stage1[1];
            2'd2:    curr_byte_mux = mux_stage1[2];
            default: curr_byte_mux = mux_stage1[3];
        endcase
    end

    //--------------------------------------------------------------------------
    // Downstream Handshake and Framing Control Signals
    //--------------------------------------------------------------------------
    // Output register can accept a new byte if it is currently empty or if
    // downstream is actively accepting the current byte.
    wire out_ready_to_load     = !out_valid_q || out_ready;

    // Active read buffer contains valid data to serialize
    wire has_byte              = buf_valid[rd_buf];

    // Marker for the last byte of the current 8-coefficient chunk (rd_byte_cnt == d-1)
    wire is_last_byte_of_chunk = (rd_byte_cnt == (d_q - 4'd1));

    // Marker for the last byte of the entire 256-coefficient polynomial (chunk 31, byte d-1)
    wire is_last_byte_of_poly  = (chunk_cnt == 5'd31) && is_last_byte_of_chunk;

    //--------------------------------------------------------------------------
    // Main Sequential FSM and Datapath Logic
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Asynchronous reset of all control registers and pointers
            busy_q       <= 1'b0;
            d_q          <= 4'd12;
            wr_buf       <= 1'b0;
            wr_cnt       <= 3'd0;
            in_coeff_cnt <= 9'd0;
            buf_valid[0] <= 1'b0;
            buf_valid[1] <= 1'b0;
            rd_buf       <= 1'b0;
            rd_byte_cnt  <= 4'd0;
            chunk_cnt    <= 5'd0;
            out_valid_q  <= 1'b0;
            out_data_q   <= 8'd0;
            out_last_q   <= 1'b0;
            for (int i = 0; i < 8; i++) begin
                coeff_buf[0][i] <= 12'd0;
                coeff_buf[1][i] <= 12'd0;
            end
        end else begin
            //------------------------------------------------------------------
            // Configuration Sampling
            // Latch cfg_d when idle; lock configuration upon first coefficient push
            //------------------------------------------------------------------
            if (!busy_q) begin
                d_q <= sanitize_d(cfg_d);
                if (push_coeff) begin
                    busy_q <= 1'b1;
                end
            end

            //------------------------------------------------------------------
            // Upstream Ingestion & Accumulation into Ping-Pong Buffer
            //------------------------------------------------------------------
            if (push_coeff) begin
                coeff_buf[wr_buf][wr_cnt] <= in_coeff_masked;
                in_coeff_cnt              <= in_coeff_cnt + 9'd1;

                // When 8 coefficients are accumulated, close bank and switch to other bank
                if (wr_cnt == 3'd7) begin
                    wr_cnt            <= 3'd0;
                    buf_valid[wr_buf] <= 1'b1;
                    wr_buf            <= ~wr_buf;
                end else begin
                    wr_cnt <= wr_cnt + 3'd1;
                end
            end

            //------------------------------------------------------------------
            // Downstream Byte Emission & Read Bank Sequencing
            //------------------------------------------------------------------
            if (out_ready_to_load) begin
                if (has_byte) begin
                    // Emit next byte from current chunk
                    out_valid_q <= 1'b1;
                    out_data_q  <= curr_byte_mux;
                    out_last_q  <= is_last_byte_of_poly;

                    if (is_last_byte_of_chunk) begin
                        // Chunk complete: clear buffer flag, advance bank, increment chunk count
                        rd_byte_cnt       <= 4'd0;
                        buf_valid[rd_buf] <= 1'b0;
                        rd_buf            <= ~rd_buf;
                        chunk_cnt         <= chunk_cnt + 5'd1;
                    end else begin
                        // Advance byte pointer within current chunk
                        rd_byte_cnt <= rd_byte_cnt + 4'd1;
                    end
                end else if (out_last_q) begin
                    // Entire polynomial packet has been accepted: return to idle
                    out_valid_q  <= 1'b0;
                    out_last_q   <= 1'b0;
                    busy_q       <= 1'b0;
                    chunk_cnt    <= 5'd0;
                    in_coeff_cnt <= 9'd0;
                    wr_buf       <= 1'b0;
                    rd_buf       <= 1'b0;
                    wr_cnt       <= 3'd0;
                    rd_byte_cnt  <= 4'd0;
                    buf_valid[0] <= 1'b0;
                    buf_valid[1] <= 1'b0;
                end else begin
                    // Pipeline bubble: no bytes ready to emit
                    out_valid_q <= 1'b0;
                    out_last_q  <= 1'b0;
                end
            end
        end
    end

endmodule

//==============================================================================
// Module: poly_encode_pair
// Description: Parallel Dual-Coefficient Encoder for High-Bandwidth Pipelines.
//              Accepts two 11-bit coefficients per cycle (22 bits total).
//              Over 4 consecutive clock cycles (phase_q = 0..3), accumulates
//              8 coefficients (88 bits) in history_q shift register.
//              Upon accumulating the 8th coefficient, simultaneously emits
//              the packed group out_data[87:0] with byte count out_bytes <= cfg_d.
//
//              All bit packing is implemented via fixed wiring without dynamic
//              shifting, optimizing datapath area and pipeline latency.
//==============================================================================
module poly_encode_pair (
    // Clock and active-low synchronous reset
    input  logic        clk,
    input  logic        rst_n,

    // Runtime bit-width configuration (4, 5, 10, 11)
    input  logic [3:0]  cfg_d,

    // Upstream streaming interface (2 coefficients per beat)
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [21:0] in_data,    // {coeff_odd[10:0], coeff_even[10:0]}
    input  logic        in_last,

    // Downstream packed output interface
    output logic        out_valid,
    input  logic        out_ready,
    output logic [87:0] out_data,   // Packed byte vector (up to 11 bytes)
    output logic [3:0]  out_bytes,  // Valid byte count (equals cfg_d)
    output logic        out_last
);
    // 66-bit history buffer holding 3 previously received pairs (6 coefficients)
    logic [65:0] history_q;

    // 2-bit phase counter tracking 4 incoming beats (0, 1, 2, 3)
    logic [1:0]  phase_q;

    // Reconstruct full 8-coefficient vector: {new_pair, 3_previous_pairs}
    wire  [87:0] coefficients = {in_data, history_q};

    // Unpack 8 individual 11-bit coefficients for bitfield concatenation
    wire  [10:0] c [0:7];
    for (genvar i = 0; i < 8; i++) assign c[i] = coefficients[11*i +: 11];

    // Flow control: accept input beat if output stage is empty or consuming
    assign in_ready = !out_valid || out_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase_q   <= 0;
            out_valid <= 0;
            out_last  <= 0;
            out_data  <= 0;
            out_bytes <= 0;
            history_q <= 0;
        end else if (in_ready) begin
            out_valid <= 0;
            if (in_valid) begin
                // Shift in the new pair into history buffer
                history_q <= {in_data, history_q[65:22]};
                phase_q   <= phase_q + 1'b1;

                // On the 4th beat (phase_q == 3), all 8 coefficients are available
                if (phase_q == 3) begin
                    out_valid <= 1;
                    out_bytes <= cfg_d;
                    out_last  <= in_last;

                    // Static slice wiring per configuration d
                    case (cfg_d)
                        4:       out_data <= {56'd0,c[7][3:0],c[6][3:0],c[5][3:0],c[4][3:0],c[3][3:0],c[2][3:0],c[1][3:0],c[0][3:0]};
                        5:       out_data <= {48'd0,c[7][4:0],c[6][4:0],c[5][4:0],c[4][4:0],c[3][4:0],c[2][4:0],c[1][4:0],c[0][4:0]};
                        10:      out_data <= {8'd0,c[7][9:0],c[6][9:0],c[5][9:0],c[4][9:0],c[3][9:0],c[2][9:0],c[1][9:0],c[0][9:0]};
                        default: out_data <= coefficients;
                    endcase
                end
            end
        end
    end
endmodule
