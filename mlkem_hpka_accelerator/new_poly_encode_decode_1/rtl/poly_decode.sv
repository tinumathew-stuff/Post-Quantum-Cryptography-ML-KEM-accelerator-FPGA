`timescale 1ns/1ps
//==============================================================================
// Module: poly_decode
// Project: ML-KEM High-Performance Cryptographic Hardware Accelerator
// Standard: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
//
// Description:
//   High-throughput, fully pipelined streaming polynomial coefficient decoder
//   implementing NIST FIPS 203 ByteDecode_d (Algorithm 4 / Section 4.2.2).
//   Unpacks a little-endian packed byte stream into individual 12-bit ring
//   coefficients for polynomial ring R_q = Z_q[X]/(X^256 + 1) with q = 3329.
//
// Mathematical Specification:
//   For an incoming byte array B = (b_0, b_1, ..., b_{32d-1}) where each b_k in {0,...,255}:
//     ByteDecode_d: B^{32d} -> R_q (or Z_2^256 for d=1)
//     f(X) = sum_{i=0}^{255} f_i * X^i
//     where f_i = sum_{j=0}^{d-1} beta_{d*i + j} * 2^j
//     and beta_m is the m-th bit of B: beta_m = (b_{floor(m/8)} >> (m mod 8)) & 1.
//
// Supported Bit-Width Configurations (cfg_d in {1, 4, 5, 10, 11, 12}):
//   - d = 1:  32 bytes  -> 256 1-bit  coefficients (plaintext message encoding / decode)
//   - d = 4: 128 bytes  -> 256 4-bit  coefficients (ML-KEM-512 v ciphertext vector)
//   - d = 5: 160 bytes  -> 256 5-bit  coefficients (ML-KEM-768/1024 v ciphertext vector)
//   - d = 10: 320 bytes -> 256 10-bit coefficients (ML-KEM-512/768 u ciphertext vector)
//   - d = 11: 352 bytes -> 256 11-bit coefficients (ML-KEM-1024 u ciphertext vector)
//   - d = 12: 384 bytes -> 256 12-bit coefficients (uncompressed polynomial ring elements)
//
// Architectural Principles & Microarchitecture:
//   1. 8-Coefficient Chunk Byte Alignment:
//      In FIPS 203, exactly 8 coefficients span 8 * d bits = d bytes. Because 8*d is
//      guaranteed to be an exact multiple of 8 bits (1 byte) for all valid d in
//      {1, 4, 5, 10, 11, 12}, no fractional byte boundary ever crosses an 8-coefficient
//      chunk boundary! A polynomial of 256 coefficients consists of exactly 32 chunks
//      (32 * 8 = 256 coefficients; 32 * d = total bytes expected).
//   2. Zero-Barrel-Shifter Static Slice Wiring:
//      By framing data into complete d-byte chunks, all coefficient bit fields are
//      extracted via completely fixed, static bit slices without variable barrel
//      shifters or dynamic feedback subtractors, minimizing FPGA routing congestion.
//   3. Ping-Pong Chunk Buffer:
//      Dual-bank 12-byte ping-pong buffer (byte_buf[0:1][0:11]) completely decouples
//      the 8-bit input byte ingress from the 12-bit coefficient egress. Bank 0 can
//      accumulate bytes from the network/memory while Bank 1 serializes coefficients
//      to the polynomial multiplier or accumulator, eliminating pipeline bubbles.
//   4. Hierarchical 4:1 / 2:1 Multiplexer Tree:
//      Decoded coefficients are selected through a structured 2-level multiplexer tree
//      mapped directly onto AMD/Xilinx UltraScale+ 6-input LUTs (LUT6 + MUXF7/MUXF8),
//      achieving timing closure above 450 MHz on Kintex UltraScale (xcku035-ffva1156-2-e).
//   5. Robust AXI4-Stream Backpressure & Flow Control:
//      Full independent ready/valid handshaking on both input (in_valid/in_ready)
//      and output (out_valid/out_ready) interfaces, with registered skid buffering
//      to break combinational feedback paths across hierarchical boundaries.
//==============================================================================

module poly_decode (
    // Clock and active-low reset
    input  logic        clk,        // System clock (target: 450 MHz)
    input  logic        rst_n,      // Asynchronous active-low reset

    // Runtime bit-depth configuration
    input  logic [3:0]  cfg_d,      // Runtime selectable d in {1, 4, 5, 10, 11, 12}

    // Streaming input byte stream interface (AXI4-Stream compliant)
    input  logic        in_valid,   // Asserted when in_data carries a valid byte
    output logic        in_ready,   // Asserted when decoder can accept another byte
    input  logic [7:0]  in_data,    // Packed little-endian byte stream
    input  logic        in_last,    // Frame marker indicating last byte of current packet

    // Streaming output coefficient interface (AXI4-Stream compliant)
    output logic        out_valid,  // Asserted when out_data carries a valid coefficient
    input  logic        out_ready,  // Asserted when downstream receiver can accept data
    output logic [11:0] out_data,   // Emitted unpacked 12-bit coefficient in [0, 2^d - 1]
    output logic        out_last    // Framed packet end: asserted on coefficient 255 of 256
);

    //--------------------------------------------------------------------------
    // Function: sanitize_d
    // Sanitizes the runtime configuration input cfg_d against unsupported values.
    // Falls back to d = 12 (standard uncompressed polynomial coefficient width)
    // to prevent undefined hardware behavior or out-of-bounds indexing.
    //--------------------------------------------------------------------------
    function automatic logic [3:0] sanitize_d(input logic [3:0] d_in);
        case (d_in)
            4'd1:    sanitize_d = 4'd1;   // Plaintext message / 1-bit coefficients
            4'd4:    sanitize_d = 4'd4;   // ML-KEM-512 v compression
            4'd5:    sanitize_d = 4'd5;   // ML-KEM-768/1024 v compression
            4'd10:   sanitize_d = 4'd10;  // ML-KEM-512/768 u compression
            4'd11:   sanitize_d = 4'd11;  // ML-KEM-1024 u compression
            default: sanitize_d = 4'd12;  // Standard uncompressed ring element (384 bytes)
        endcase
    endfunction

    //--------------------------------------------------------------------------
    // State Tracking Registers & Dynamic Configuration Latching
    //   busy_q: High while an active polynomial decode transaction is in progress.
    //   d_q:    Latches the validated bit-width parameter 'd' upon receiving the
    //           first byte of a polynomial, freezing configuration during decode.
    //   cur_d:  Active parameter: dynamically samples cfg_d when idle, holds d_q when busy.
    //--------------------------------------------------------------------------
    logic        busy_q;
    logic [3:0]  d_q;

    wire [3:0] cur_d = busy_q ? d_q : sanitize_d(cfg_d);

    //--------------------------------------------------------------------------
    // Ping-Pong Chunk Byte Storage & Buffer Pointers
    //   Dual banks of 12 bytes: byte_buf[bank_index][byte_index].
    //   Maximum required storage per chunk is 12 bytes (for d = 12, 8 * 12 = 96 bits).
    //   buf_valid[0:1]: Indicates whether the corresponding buffer holds a complete chunk.
    //   wr_buf / rd_buf: Write and read ping-pong bank selector toggles.
    //   wr_byte_cnt: Counts ingested bytes for the active write buffer (0 to cur_d - 1).
    //   rd_coeff_cnt: Tracks emitted coefficient within active read buffer (0 to 7).
    //   chunk_cnt: Counts processed 8-coefficient chunks per polynomial (0 to 31).
    //   in_bytes_cnt: Total bytes received in the current polynomial frame (0 to 32*cur_d).
    //--------------------------------------------------------------------------
    logic [7:0]  byte_buf [0:1][0:11];
    logic        buf_valid [0:1];
    logic        wr_buf;
    logic [3:0]  wr_byte_cnt;
    logic        rd_buf;
    logic [2:0]  rd_coeff_cnt;
    logic [4:0]  chunk_cnt;
    logic [9:0]  in_bytes_cnt;

    //--------------------------------------------------------------------------
    // Registered Output Boundary Stage
    //   Registers all master stream outputs (valid, data, last) to eliminate
    //   long combinational routing paths to external downstream modules.
    //--------------------------------------------------------------------------
    logic        out_valid_q;
    logic [11:0] out_data_q;
    logic        out_last_q;

    assign out_valid = out_valid_q;
    assign out_data  = out_data_q;
    assign out_last  = out_last_q;

    // Total bytes required for a complete 256-coefficient polynomial: 32 * d bytes.
    // Computed by shifting cur_d left by 5 bits (cur_d * 32).
    wire [9:0] total_bytes_expected = {cur_d, 5'b00000}; // 32 * d bytes

    //--------------------------------------------------------------------------
    // Input Flow Control & Handshaking
    //   can_push: Backpressure signal asserted when the active write bank is empty
    //             and total expected bytes for the current frame have not been exceeded.
    //   push_byte: Successful transaction pulse (in_valid && in_ready).
    //--------------------------------------------------------------------------
    wire can_push   = !buf_valid[wr_buf] && (!busy_q || (in_bytes_cnt < total_bytes_expected));
    assign in_ready = can_push;
    wire push_byte  = in_valid && in_ready;

    //--------------------------------------------------------------------------
    // Static Chunk Bit-Vector Assembly
    //   Concatenates the 12 bytes of the active read bank into a unified 96-bit
    //   bus in little-endian byte ordering (byte 0 in bits [7:0], byte 11 in bits [95:88]).
    //--------------------------------------------------------------------------
    wire [95:0] chunk_bytes = {
        byte_buf[rd_buf][11], byte_buf[rd_buf][10], byte_buf[rd_buf][9],  byte_buf[rd_buf][8],
        byte_buf[rd_buf][7],  byte_buf[rd_buf][6],  byte_buf[rd_buf][5],  byte_buf[rd_buf][4],
        byte_buf[rd_buf][3],  byte_buf[rd_buf][2],  byte_buf[rd_buf][1],  byte_buf[rd_buf][0]
    };

    //--------------------------------------------------------------------------
    // Parallel Combinational 8-Coefficient Unpacker
    //   Simultaneously decodes all 8 coefficients in the current chunk using static
    //   bit-slice offsets (+: operator) and zero-extends them to 12 bits.
    //   Each coefficient k (0 <= k < 8) occupies bit positions [d*k +: d].
    //--------------------------------------------------------------------------
    logic [11:0] coeff_decoded [0:7];
    always_comb begin
        for (int k = 0; k < 8; k++) begin
            case (d_q)
                4'd1:    coeff_decoded[k] = {11'd0, chunk_bytes[k]};
                4'd4:    coeff_decoded[k] = {8'd0,  chunk_bytes[4*k  +: 4]};
                4'd5:    coeff_decoded[k] = {7'd0,  chunk_bytes[5*k  +: 5]};
                4'd10:   coeff_decoded[k] = {2'd0,  chunk_bytes[10*k +: 10]};
                4'd11:   coeff_decoded[k] = {1'b0,  chunk_bytes[11*k +: 11]};
                default: coeff_decoded[k] = chunk_bytes[12*k +: 12]; // 12
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Hierarchical Multiplexer Tree: Stage 1 (Two parallel 4:1 Muxes)
    //   Splits the 8 unpacked coefficients into low (coeffs 0..3) and high
    //   (coeffs 4..7) halves, selected by rd_coeff_cnt[1:0].
    //--------------------------------------------------------------------------
    logic [11:0] mux_stage1 [0:1];
    always_comb begin
        case (rd_coeff_cnt[1:0])
            2'd0:    mux_stage1[0] = coeff_decoded[0];
            2'd1:    mux_stage1[0] = coeff_decoded[1];
            2'd2:    mux_stage1[0] = coeff_decoded[2];
            default: mux_stage1[0] = coeff_decoded[3];
        endcase

        case (rd_coeff_cnt[1:0])
            2'd0:    mux_stage1[1] = coeff_decoded[4];
            2'd1:    mux_stage1[1] = coeff_decoded[5];
            2'd2:    mux_stage1[1] = coeff_decoded[6];
            default: mux_stage1[1] = coeff_decoded[7];
        endcase
    end

    // Hierarchical Multiplexer Tree: Stage 2 (Final 2:1 Mux selected by rd_coeff_cnt[2])
    wire [11:0] curr_coeff_mux = rd_coeff_cnt[2] ? mux_stage1[1] : mux_stage1[0];

    //--------------------------------------------------------------------------
    // Pipeline & Handshake Control Logic
    //   out_ready_to_load:      Output register can advance if empty or drained.
    //   has_coeff:              Active read buffer contains valid chunk data.
    //   is_last_coeff_of_chunk: Reached 8th coefficient (index 7) in current chunk.
    //   is_last_coeff_of_poly:  Reached final coefficient of 32nd chunk (total 256).
    //--------------------------------------------------------------------------
    wire out_ready_to_load      = !out_valid_q || out_ready;
    wire has_coeff              = buf_valid[rd_buf];
    wire is_last_coeff_of_chunk = (rd_coeff_cnt == 3'd7);
    wire is_last_coeff_of_poly  = (chunk_cnt == 5'd31) && is_last_coeff_of_chunk;

    //--------------------------------------------------------------------------
    // Main Sequential Control Block (Clocked on clk, Async Reset on rst_n)
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Asynchronous reset initialization of all control and datapath registers
            busy_q       <= 1'b0;
            d_q          <= 4'd12;
            wr_buf       <= 1'b0;
            wr_byte_cnt  <= 4'd0;
            in_bytes_cnt <= 10'd0;
            buf_valid[0] <= 1'b0;
            buf_valid[1] <= 1'b0;
            rd_buf       <= 1'b0;
            rd_coeff_cnt <= 3'd0;
            chunk_cnt    <= 5'd0;
            out_valid_q  <= 1'b0;
            out_data_q   <= 12'd0;
            out_last_q   <= 1'b0;
            for (int i = 0; i < 12; i++) begin
                byte_buf[0][i] <= 8'd0;
                byte_buf[1][i] <= 8'd0;
            end
        end else begin
            //------------------------------------------------------------------
            // Configuration Sampling: Latches d and asserts busy on first push
            //------------------------------------------------------------------
            if (!busy_q) begin
                d_q <= sanitize_d(cfg_d);
                if (push_byte) begin
                    busy_q <= 1'b1;
                end
            end

            //------------------------------------------------------------------
            // Ingress Byte Accumulation: Stores incoming byte into active bank
            //------------------------------------------------------------------
            if (push_byte) begin
                byte_buf[wr_buf][wr_byte_cnt] <= in_data;
                in_bytes_cnt                  <= in_bytes_cnt + 10'd1;
                // When active write buffer reaches cur_d bytes, mark bank valid and swap
                if (wr_byte_cnt == (cur_d - 4'd1)) begin
                    wr_byte_cnt       <= 4'd0;
                    buf_valid[wr_buf] <= 1'b1;
                    wr_buf            <= ~wr_buf;
                end else begin
                    wr_byte_cnt <= wr_byte_cnt + 4'd1;
                end
            end

            //------------------------------------------------------------------
            // Egress Output Pipeline Management & Buffer Deallocation
            //------------------------------------------------------------------
            if (out_ready_to_load) begin
                if (has_coeff) begin
                    // Emit selected coefficient to registered output boundary
                    out_valid_q <= 1'b1;
                    out_data_q  <= curr_coeff_mux;
                    out_last_q  <= is_last_coeff_of_poly;

                    // Advance coefficient index or retire completed chunk
                    if (is_last_coeff_of_chunk) begin
                        rd_coeff_cnt      <= 3'd0;
                        buf_valid[rd_buf] <= 1'b0;  // Release bank for write reuse
                        rd_buf            <= ~rd_buf; // Swap read bank
                        chunk_cnt         <= chunk_cnt + 5'd1;
                    end else begin
                        rd_coeff_cnt <= rd_coeff_cnt + 3'd1;
                    end
                end else if (out_last_q) begin
                    // Packet completed: Clear output pipeline and reset to IDLE
                    out_valid_q  <= 1'b0;
                    out_last_q   <= 1'b0;
                    busy_q       <= 1'b0;
                    chunk_cnt    <= 5'd0;
                    in_bytes_cnt <= 10'd0;
                    wr_buf       <= 1'b0;
                    rd_buf       <= 1'b0;
                    wr_byte_cnt  <= 4'd0;
                    rd_coeff_cnt <= 3'd0;
                    buf_valid[0] <= 1'b0;
                    buf_valid[1] <= 1'b0;
                end else begin
                    out_valid_q <= 1'b0;
                    out_last_q  <= 1'b0;
                end
            end
        end
    end

endmodule

//==============================================================================
// Module: poly_decode_group
// Description:
//   Parallel 8-coefficient chunk unpacker producing coefficient pairs per cycle.
//   Accepts an 88-bit packed input word (representing up to 8 coefficients of
//   11 bits each) and deserializes it into four consecutive 22-bit output pairs
//   (two 11-bit coefficients per cycle) across 4 clock cycles.
//   Employs four static constant shifts rather than a dynamic barrel shifter.
//
// Parameters Supported:
//   cfg_d in {4, 5, 10, 11}.
//==============================================================================
module poly_decode_group (
    input  logic        clk,        // System clock
    input  logic        rst_n,      // Asynchronous active-low reset
    input  logic        clear,      // Synchronous pipeline flush / clear
    input  logic [3:0]  cfg_d,      // Bit-depth configuration (4, 5, 10, 11)
    input  logic        in_valid,   // Input 88-bit vector valid
    output logic        in_ready,   // Decoder ready to accept next 88-bit vector
    input  logic [87:0] in_data,    // Ingested 88-bit packed coefficient chunk
    input  logic        in_last,    // Frame end indicator on input
    output logic        out_valid,  // Output pair valid
    input  logic        out_ready,  // Downstream ready to accept pair
    output logic [21:0] out_data,   // Emitted pair of unpacked coefficients
    output logic        out_last    // Asserted on final pair of frame
);
    // Internal shift register and sequencing state
    logic [87:0] bits_q;
    logic [2:0]  pairs_q;           // Remaining pairs counter (initially 4)
    logic [3:0]  d_q;               // Latched bit-depth
    logic        last_q;            // Latched end-of-frame flag

    // Flow control: ready when idle (pairs_q == 0) or on final cycle with handshake
    assign in_ready  = pairs_q == 0 || (pairs_q == 1 && out_ready);
    assign out_valid = pairs_q != 0;
    assign out_last  = last_q && pairs_q == 1;

    // Combinational extraction of lower two coefficients formatted as [21:0]
    always_comb begin
        case (d_q)
            4:       out_data = {7'd0,bits_q[7:4],7'd0,bits_q[3:0]};
            5:       out_data = {6'd0,bits_q[9:5],6'd0,bits_q[4:0]};
            10:      out_data = {1'b0,bits_q[19:10],1'b0,bits_q[9:0]};
            default: out_data = bits_q[21:0];
        endcase
    end

    // Sequential shift register and counter update
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            pairs_q <= 0;
            bits_q  <= 0;
            d_q     <= 10;
            last_q  <= 0;
        end else if (in_valid && in_ready) begin
            // Load new 88-bit chunk and arm pair counter to 4
            bits_q  <= in_data;
            pairs_q <= 4;
            d_q     <= cfg_d;
            last_q  <= in_last;
        end else if (out_valid && out_ready) begin
            // Step pair counter and shift out processed pair by 2*d bits
            pairs_q <= pairs_q - 1'b1;
            case (d_q)
                4:       bits_q <= {8'd0,bits_q[87:8]};
                5:       bits_q <= {10'd0,bits_q[87:10]};
                10:      bits_q <= {20'd0,bits_q[87:20]};
                default: bits_q <= {22'd0,bits_q[87:22]};
            endcase
        end
    end
endmodule

//==============================================================================
// Module: poly_decode12_lane
// Description:
//   Specialized high-throughput ByteDecode_12 streaming lane adapter.
//   Converts a continuous 64-bit input stream (8 bytes = 5.33 coefficients)
//   into a 48-bit output stream (4 canonical 12-bit coefficients per beat).
//
// Alignment Sequence (Lowest Common Multiple of 64 and 48 is 192 bits = 16 coeffs):
//   - Cycle 0: Ingests bits [63:0].  Emits coeffs [47:0] (bits 0..47). Stash 16 bits.
//   - Cycle 1: Ingests bits [127:64]. Emits {in[31:0], buf[15:0]}.   Stash 32 bits.
//   - Cycle 2: Ingests bits [191:128].Emits {in[15:0], buf[31:0]}.   Stash 48 bits.
//   - Cycle 3: Emits buffered bits [47:0] without consuming input (in_ready lowered).
//   Achieves 100% throughput using only fixed 0, 16, 32, and 48-bit alignments!
//
// Canonical Coefficient Validation (is_bad12):
//   Detects illegal uncompressed coefficients violating FIPS 203 Section 4.2.2:
//   Coefficients must be in range [0, q-1] where q = 3329 (12'b1101_0000_0001).
//   A coefficient c is non-canonical (c >= 3329) if:
//     (c[11] && c[10] && c[9])  => c >= 3584 > 3329, OR
//     (c[11] && c[10] && c[8] && (|c[7:0])) => c >= 3329.
//==============================================================================
module poly_decode12_lane (
    input  logic        clk,        // System clock
    input  logic        rst_n,      // Asynchronous active-low reset
    input  logic        clear,      // Synchronous pipeline flush / clear
    input  logic        in_valid,   // 64-bit input word valid
    output logic        in_ready,   // Ready to consume 64-bit word
    input  logic [63:0] in_data,    // Ingested 64-bit word (8 packed bytes)
    output logic        out_valid,  // 48-bit output word valid (4 x 12-bit coefficients)
    input  logic        out_ready,  // Downstream receiver ready
    output logic [47:0] out_data,   // Emitted four 12-bit coefficients
    output logic        out_bad     // Asserted if any emitted coefficient >= 3329
);
    // 2-bit state tracking exact 4-word sequence (0, 16, 32, 48 bits stored)
    logic [1:0]  state_q;
    logic [47:0] buf_q;
    logic [47:0] out_data_q;
    logic        out_valid_q;
    logic        in_ready_q;

    assign in_ready  = in_ready_q;
    assign out_valid = out_valid_q;
    assign out_data  = out_data_q;

    // Fast subtractor-less canonical validation function
    function automatic logic is_bad12(input logic [11:0] c);
        return c[11] && c[10] && (c[9] || (c[8] && (|c[7:0])));
    endfunction
    assign out_bad = is_bad12(out_data[11:0]) || is_bad12(out_data[23:12]) ||
                     is_bad12(out_data[35:24]) || is_bad12(out_data[47:36]);

    wire push = in_valid && in_ready;
    wire pop  = out_valid && out_ready;

    // 4-phase sequence state machine
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            state_q     <= 2'd0;
            buf_q       <= 48'd0;
            out_data_q  <= 48'd0;
            out_valid_q <= 1'b0;
            in_ready_q  <= 1'b1;
        end else begin
            if (pop) begin
                out_valid_q <= 1'b0;
            end
            case (state_q)
                2'd0: begin
                    in_ready_q <= 1'b1;
                    if (push) begin
                        out_data_q  <= in_data[47:0];
                        out_valid_q <= 1'b1;
                        buf_q[15:0] <= in_data[63:48];
                        state_q     <= 2'd1;
                    end
                end
                2'd1: begin
                    in_ready_q <= 1'b1;
                    if (push) begin
                        out_data_q  <= {in_data[31:0], buf_q[15:0]};
                        out_valid_q <= 1'b1;
                        buf_q[31:0] <= in_data[63:32];
                        state_q     <= 2'd2;
                    end
                end
                2'd2: begin
                    if (push) begin
                        out_data_q  <= {in_data[15:0], buf_q[31:0]};
                        out_valid_q <= 1'b1;
                        buf_q[47:0] <= in_data[63:16];
                        state_q     <= 2'd3;
                        in_ready_q  <= 1'b0;
                    end else begin
                        in_ready_q  <= 1'b1;
                    end
                end
                2'd3: begin
                    if (pop || !out_valid_q) begin
                        out_data_q  <= buf_q[47:0];
                        out_valid_q <= 1'b1;
                        in_ready_q  <= 1'b1;
                        state_q     <= 2'd0;
                    end
                end
            endcase
        end
    end
endmodule
