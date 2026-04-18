`timescale 1ns/1ps

//==================================================================================================
// File Name   : mlkem_hash_sampler.sv
// Project     : High-Performance ML-KEM Hardware Accelerator (FIPS 203 Post-Quantum Cryptography)
// Target Tech : AMD Kintex UltraScale / UltraScale+ (xcku035-ffva1156-2-e)
// Standards   : NIST FIPS 203 (ML-KEM), NIST FIPS 202 (SHA-3 / SHAKE)
// Author      : Accelerated Cryptography Engineering Group
// Description :
//   Unified cryptographic hashing, pseudorandom matrix sampling, and Centered Binomial
//   Distribution (CBD) noise sampling engine. The module integrates a high-throughput 24-round
//   Keccak-f[1600] permutation core with custom hardware datapaths for:
//
//   1. SHA3-256 / SHA3-512 Digest Generation:
//      - Computes cryptographic hashes for root seeds, message digests, and key derivation.
//      - Supports standard byte-stream interface as well as an ultra-fast 64-bit lane interface.
//      - Dual-digest output port for single-cycle delivery of (rho, sigma) from SHA3-512(seed_d || seed_hi).
//
//   2. SHAKE-128 Matrix Rejection Sampler (SampleNTT):
//      - Expands the public matrix A \in R_q^{k x k} from public seed rho (32 bytes) and coordinates (row, col).
//      - Squeezes 168-byte (1344-bit rate) Keccak output blocks.
//      - Implements 4-candidate parallel rejection testing against modulus q = 3329.
//      - Utilizes a constant-depth barrel compaction network and a 36-bit residue accumulator.
//      - Streams out aligned 48-bit beats containing four valid 12-bit coefficients per clock.
//      - Features autonomous multi-polynomial row/column traversal with Keccak prefetch overlapping.
//
//   3. SHAKE-256 Centered Binomial Distribution (CBD) Noise Sampler (SamplePolyCBD):
//      - Generates secret vectors s \in R_q^k and error vectors e \in R_q^k from seed sigma (32 bytes) and nonce N.
//      - Supports both eta = 2 (ML-KEM-768/1024, ML-KEM-512 error) and eta = 3 (ML-KEM-512 secret/error).
//      - Bitwise parallel binomial addition trees:
//          * eta = 2: 16 input bits -> 4 coefficients (mod 3329) per beat.
//          * eta = 3: 24 input bits -> 4 coefficients (mod 3329) per beat via 3-bit carry-save adder logic.
//      - Compact streaming shift buffer maintaining 100% throughput across word/block boundaries.
//
//==================================================================================================
// Microarchitecture Block Diagram:
//
//        +-------------------------------------------------------------------------------+
//        |                          mlkem_hash_sampler                                  |
//        |                                                                               |
//        |   +-----------------------+                +------------------------------+   |
//  cmd_* ===>| Command & Sequencing  |===============>|      Keccak-f[1600] Core     |   |
//            | One-Hot FSM (15 St.)  |                |      24-Round Permutation    |   |
//            +-----------------------+                +------------------------------+   |
//                        |                                           |                   |
//                        v                                           v (core_out: 1600b) |
//   +--------------------+---------------------+      +------------------------------+   |
//   |         Unified Absorb Buffer            |      | Compact Streaming Buffer     |   |
//   | (17 x 64-bit Lane / Byte Stream Merger)  |      | Shift Register (28 x 48-bit) |   |
//   +------------------------------------------+      +------------------------------+   |
//            ^                      ^                                |                   |
//            |                      |               +----------------+---------------+   |
//   in_lane_*|                      |in_data (bytes)|                                |   |
//  (64b fast)|                      |(8b standard)  v                                v   |
//            |                                 [Rejection Sampler]          [CBD Sampler]|
//                                              | 4-Way 12-bit Filter|       | eta=2 / 3  |
//                                              | < 3329 Comparison  |       | Binomial   |
//                                              | Compaction Network |       | Trees      |
//                                              | 36-bit Residue FIFO|       +-----+------+
//                                              +---------+----------+             |      |
//                                                        |                        |      |
//                                                        v                        v      |
//                                                 +--------------+         +-------------+
//                                                 | mat_out_data |         |vec_out_data |
//                                                 | (48b / 4 c.) |         |(48b / 4 c.) |
//                                                 +--------------+         +-------------+
//==================================================================================================

module mlkem_hash_sampler #(
    parameter bit ENABLE_BYTE_STREAM = 1  // When enabled, instantiates byte-serial absorb logic (default: 1)
)(
    //----------------------------------------------------------------------------------------------
    // Clock and Active-Low Synchronous Reset
    //----------------------------------------------------------------------------------------------
    input  logic         clk,                    // System clock (nominal: 450 MHz)
    input  logic         rst_n,                  // Asynchronous active-low system reset

    //----------------------------------------------------------------------------------------------
    // Command and Control Interface
    //----------------------------------------------------------------------------------------------
    input  logic         cmd_valid,              // Command valid strobe (1 cycle pulse or asserted until ready)
    output logic         cmd_ready,              // High when engine is idle and ready for new command
    input  logic [2:0]   cmd_mode,               // Operational Mode:
                                                 //   3'd0: SHA3-256 (rate 1088 bits)
                                                 //   3'd1: SHA3-512 (rate 576 bits)
                                                 //   3'd2: MATRIX (SHAKE-128 Rejection Sampler for A)
                                                 //   3'd3: VECTOR (SHAKE-256 CBD Sampler for s and e)
                                                 //   3'd4: SHAKE-256 general sponge
                                                 //   3'd5: SHA512_64 (64-byte absorb: seed || seed_hi)
    input  logic [2:0]   cmd_k,                  // Lattice rank k: 2 (ML-KEM-512), 3 (ML-KEM-768), 4 (ML-KEM-1024)
    input  logic [255:0] cmd_seed,               // 256-bit seed (rho for matrix, sigma for vector, seed_d for SHA)
    input  logic [255:0] cmd_seed_hi = 256'd0,   // High 256 bits of seed for mode 5 (SHA3-512 of 512-bit message)
    input  logic         cmd_transpose,          // Public matrix transpose flag: 0 for A[row,col], 1 for A^T[row,col]
    input  logic         cmd_eta3,               // CBD width flag: 0 for eta=2, 1 for eta=3
    input  logic [7:0]   cmd_nonce,              // Base nonce N for vector sampling (typically 0 or k)

    //----------------------------------------------------------------------------------------------
    // Standard Byte-Stream Input Interface (FIPS 202 Message Stream)
    //----------------------------------------------------------------------------------------------
    input  logic         in_valid,               // Input byte valid
    output logic         in_ready,               // Input byte ready (backpressure flow control)
    input  logic [7:0]   in_data,                // Message data byte
    input  logic         in_last,                // End of message packet indicator
    input  logic         in_keep,                // Byte keep flag (zero indicates an empty final packet beat)

    //----------------------------------------------------------------------------------------------
    // Fast 64-bit Lane Absorb Interface (High-Throughput Key Generation / Decapsulation)
    //----------------------------------------------------------------------------------------------
    input  logic         in_lane_mode = 1'b0,    // 1: Bypass byte-serial logic; absorb directly via 64-bit lanes
    input  logic         in_lane_valid = 1'b0,   // 64-bit lane valid
    output logic         in_lane_ready,          // Ready to accept next 64-bit lane
    input  logic [63:0]  in_lane = 64'd0,        // 64-bit lane word
    input  logic         in_last_block = 1'b0,   // High on the final block of a multi-block absorb sequence
    input  logic [4:0]   in_rem_lanes = 5'd0,    // Number of active lanes in the final block (0..16)

    //----------------------------------------------------------------------------------------------
    // Cryptographic Digest Output Interface
    //----------------------------------------------------------------------------------------------
    output logic         digest_valid,           // High when digest output registers contain valid hash output
    output logic [255:0] digest_out,             // Primary 256-bit digest output (e.g., rho from G(d))
    output logic [255:0] digest_out_sigma,       // Secondary 256-bit digest output (e.g., sigma from G(d))

    //----------------------------------------------------------------------------------------------
    // Coefficient Streaming and Status Interface
    //----------------------------------------------------------------------------------------------
    output logic         out_valid,              // General valid strobe for output data stream
    output logic         mat_out_valid,          // Dedicated valid strobe for Matrix A stream
    output logic         vec_out_valid,          // Dedicated valid strobe for Vector s/e stream
    input  logic         out_ready,              // External consumer ready for general stream
    input  logic         mat_out_ready = 1'b1,   // External consumer ready for Matrix A stream
    input  logic         vec_out_ready = 1'b1,   // External consumer ready for Vector stream
    output logic [47:0]  out_data,               // Up to four 12-bit coefficients [c3, c2, c1, c0]; Hash uses [7:0]
    output logic [47:0]  mat_out_data,           // Dedicated 48-bit matrix candidate bus
    output logic [2:0]   out_count,              // Number of valid items on out_data (4 for samplers, 1 for byte)
    output logic         out_last,               // High on the last beat of a polynomial (coeff 252..255) or digest
    output logic [3:0]   out_poly_index,         // Index of polynomial currently streaming out (0 to k-1 or k*k-1)
    output logic         cmd_done                // Asserted for 1 cycle upon total command completion
);

    //==============================================================================================
    // Command Mode Parameter Definitions
    //==============================================================================================
    localparam logic [2:0] SHA256    = 3'd0,     // Standard SHA3-256 (rate = 136 bytes)
                           SHA512    = 3'd1,     // Standard SHA3-512 (rate = 72 bytes)
                           MATRIX    = 3'd2,     // SHAKE-128 Rejection Sampler for Public Matrix A
                           VECTOR    = 3'd3,     // SHAKE-256 CBD Sampler for Secret/Error Vectors
                           SHAKE256  = 3'd4,     // SHAKE-256 general stream
                           SHA512_64 = 3'd5;     // SHA3-512 with 64-byte absorb (seed_d || seed_hi)

    //==============================================================================================
    // Finite State Machine (FSM) State Encodings (One-Hot Encoded)
    //==============================================================================================
    localparam int S_IDLE             = 0;       // Idle / waiting for cmd_valid
    localparam int S_START            = 1;       // Initialize Keccak permutation with domain padding / seed
    localparam int S_WAIT0            = 2;       // Wait for Keccak core permutation of block 0
    localparam int S_WAIT_VECTOR1     = 3;       // Wait for Keccak core permutation of vector block 1 (eta=3)
    localparam int S_MATRIX_SCAN      = 4;       // Scan buffer words, reject candidates >= 3329, stage output
    localparam int S_MATRIX_MORE      = 5;       // Squeeze additional Keccak blocks when buffer runs dry
    localparam int S_VECTOR_SCAN      = 6;       // Scan buffer words, perform CBD expansion, stream out
    localparam int S_HASH_OUT         = 7;       // Stream hash digest bytes over out_data[7:0]
    localparam int S_NEXT_POLY        = 8;       // Advance polynomial index (row/col update for matrix A)
    localparam int S_HASH_ABSORB      = 9;       // Byte-serial message absorption into rate buffer
    localparam int S_HASH_START_FULL  = 10;      // Trigger Keccak permutation on intermediate full block
    localparam int S_HASH_WAIT_FULL   = 11;      // Wait for Keccak permutation on intermediate full block
    localparam int S_HASH_START_FINAL = 12;      // Trigger Keccak permutation on final padded block
    localparam int S_HASH_WAIT_FINAL  = 13;      // Wait for Keccak permutation on final padded block
    localparam int S_LANE_HASH        = 14;      // 64-bit high-throughput lane absorb sequencing
    localparam int NUM_STATES         = 15;      // Total number of states in one-hot state vector

    // Explicit One-Hot State Register (Zero decode logic, permanent VCC clock-enable)
    logic [NUM_STATES-1:0] fsm_q, next_fsm;

    //==============================================================================================
    // Internal Registers and Control Signals
    //==============================================================================================
    logic [2:0] mode_q;                          // Latched command mode
    logic is_matrix_q, is_vector_q, is_shake_q, is_sha512_q, is_hash_q;
    logic [2:0] k_q;                              // Latched rank k
    logic [2:0] k_minus1_q;                      // Precomputed k - 1 for zero-overhead boundary comparison
    logic [255:0] seed_q;                        // Latched 256-bit seed (rho, sigma, or seed_d)
    logic [255:0] seed_hi_q;                     // Latched high 256-bit seed
    logic transpose_q, eta3_q;                   // Latched configuration flags
    logic [7:0] nonce_q;                         // Latched base nonce
    logic [7:0] vec_poly_nonce_q, vec_poly_nonce_next_q; // Active and lookahead nonces for vector sampling
    logic [2:0] row_q, col_q;                    // Current row and column of matrix A: A[row, col]
    logic [2:0] next_row_q, next_col_q;          // Precomputed lookahead row and column for prefetching
    logic has_more_matrix_polys_q;               // 1 if more matrix polynomials remain to be generated
    logic is_last_matrix_poly_q;                 // 1 if current matrix polynomial is the final one (k-1, k-1)
    logic [3:0] poly_q;                          // Active absorbing/sampling polynomial counter
    logic [3:0] scan_poly_q;                     // Active streaming/output polynomial counter
    logic [8:0] coeff_q;                         // Coefficient progress counter within polynomial (0..256 step 4)
    logic coeff_is_252_q;                        // Fast early-flag: asserted when coeff_q == 248 (next beat completes poly)
    logic [47:0] mat_cand_reg;                   // 48-bit holding register for raw candidate 12-bit words
    logic [4:0]  mat_beat_q;                     // Matrix scan beat counter within a 168-byte Keccak rate block (0..27)
    logic [5:0]  vec_group_q;                    // Vector group counter: 64 groups of 4 coefficients = 256 coefficients
    logic [23:0] cbd_word_q;                     // 24-bit input word sliced from stream buffer for CBD expansion
    logic [47:0] cbd_data_q;                     // 48-bit precomputed CBD coefficient quartet
    logic [1:0]  slice_q;                        // Sub-word slice pointer within stream buffer words

    //==============================================================================================
    // Mathematical Helper Functions
    //==============================================================================================

    //----------------------------------------------------------------------------------------------
    // modq_sub: Constant-time modular subtraction in Z_q, where q = 3329.
    // Inputs:  a, b in {0..3} (from binomial sums).
    // Output:  (a - b) mod 3329 in range [0, 3328].
    //----------------------------------------------------------------------------------------------
    function automatic logic [11:0] modq_sub(input logic [2:0] a, input logic [2:0] b);
        if (a >= b) modq_sub = {9'b0, a} - {9'b0, b};
        else modq_sub = 12'd3329 + {9'b0, a} - {9'b0, b};
    endfunction

    //----------------------------------------------------------------------------------------------
    // calc_cbd_eta2: Centered Binomial Distribution Sampler for eta = 2 (FIPS 203 Section 4.2.2).
    // Takes 16 bits of randomness w[15:0].
    // Computes 4 independent coefficients:
    //   coeff[i] = (w[4*i + 0] + w[4*i + 1]) - (w[4*i + 2] + w[4*i + 3]) mod 3329
    // Returns 48-bit packed vector: {coeff[3], coeff[2], coeff[1], coeff[0]}.
    //----------------------------------------------------------------------------------------------
    function automatic logic [47:0] calc_cbd_eta2(input logic [15:0] w);
        calc_cbd_eta2[11:0]  = modq_sub({1'b0, w[0]}  + {1'b0, w[1]},
                                        {1'b0, w[2]}  + {1'b0, w[3]});
        calc_cbd_eta2[23:12] = modq_sub({1'b0, w[4]}  + {1'b0, w[5]},
                                        {1'b0, w[6]}  + {1'b0, w[7]});
        calc_cbd_eta2[35:24] = modq_sub({1'b0, w[8]}  + {1'b0, w[9]},
                                        {1'b0, w[10]} + {1'b0, w[11]});
        calc_cbd_eta2[47:36] = modq_sub({1'b0, w[12]} + {1'b0, w[13]},
                                        {1'b0, w[14]} + {1'b0, w[15]});
    endfunction

    //----------------------------------------------------------------------------------------------
    // calc_cbd_eta3: Centered Binomial Distribution Sampler for eta = 3 (FIPS 203 Section 4.2.2).
    // Takes 24 bits of randomness w[23:0].
    // Parallel bit-summation using bitwise masking:
    //   sum = (w & 0x249249) + ((w >> 1) & 0x249249) + ((w >> 2) & 0x249249)
    // Computes 4 independent coefficients:
    //   coeff[i] = sum[6*i +: 3] - sum[6*i + 3 +: 3] mod 3329
    // Returns 48-bit packed vector: {coeff[3], coeff[2], coeff[1], coeff[0]}.
    //----------------------------------------------------------------------------------------------
    function automatic logic [47:0] calc_cbd_eta3(input logic [23:0] w);
        logic [23:0] sum;
        logic [11:0] coeff [0:3];
        sum = (w & 24'h249249) +
              ((w >> 1) & 24'h249249) +
              ((w >> 2) & 24'h249249);
        for (integer t=0; t<4; t=t+1) begin
            coeff[t] = modq_sub(sum[t*6 +: 3], sum[t*6+3 +: 3]);
        end
        calc_cbd_eta3 = {coeff[3], coeff[2], coeff[1], coeff[0]};
    endfunction

    //----------------------------------------------------------------------------------------------
    // calc_cbd_data: Multiplexed CBD evaluator selecting between eta=2 and eta=3.
    //----------------------------------------------------------------------------------------------
    function automatic logic [47:0] calc_cbd_data(input logic [23:0] w, input logic is_eta3);
        calc_cbd_data = is_eta3 ? calc_cbd_eta3(w) : calc_cbd_eta2(w[15:0]);
    endfunction

    //==============================================================================================
    // Keccak Core Interconnect and State Signals
    //==============================================================================================
    logic [6:0]  hash_idx_q;                     // Byte index for serial digest output streaming
    logic [7:0]  hash_pos_q;                     // Buffer write byte pointer
    logic [7:0]  hash_count_q;                   // Remaining bytes in current Keccak rate block
    logic hash_last_byte_q;                      // 1 when current byte is the final byte of rate capacity
    logic hash_first_q, hash_final_after_full_q; // Absorb state tracking flags
    logic [7:0] hash_rate;                       // Rate capacity in bytes (136 for SHA3-256/SHAKE, 72 for SHA3-512)
    wire [1087:0] hash_block;                    // Reconstructed 136-byte absorb block from internal buffers
    logic [1599:0] core_in, core_out;            // Keccak 1600-bit state input and output vectors
    logic core_start, core_ready, core_done;     // Keccak execution handshakes
    logic core_load, core_absorb, core_absorb_first; // Keccak control strobes
    logic block_load, block_load_vector1;        // Buffer load strobes from Keccak output
    logic [1:0] block_idx_q;                     // Squeeze block index (0..3 for matrix A, 0..1 for vector)
    logic has_more_polys_q;                      // Status flag indicating remaining polynomials in vector/matrix
    logic start_at_wait0_q;                      // Optimization flag to bypass S_START during pipelining

    // Compact Streaming Buffer / Shift Register:
    // Holds 28 words of 48 bits (1344 bits total = 168 bytes, exactly one SHAKE-128 rate block).
    logic [47:0] stream_buf [0:27];
    logic [7:0]  last_byte_q;                    // Preserves leftover byte 135 across vector block boundaries

    // Single Merged 17x64-bit Absorb Buffer (replaces lane_buf_q [0:16] and hash_byte_q [0:135]):
    // Stores up to 1088 bits of absorb data in 17 parallel 64-bit lanes.
    logic [63:0] absorb_buf_q [0:16] = '{default: '0};
    logic [4:0]  lane_in_cnt_q;                  // Lane count pointer during 64-bit lane absorb
    logic [16:0] lane_in_sel_q;                  // One-hot write enable selector across the 17 lanes
    logic        lane_block_ready_q;             // Asserted when a complete rate block is buffered
    logic        lane_is_last_block_q;           // Latched final block flag
    logic [4:0]  lane_rem_lanes_q;               // Number of valid lanes in final block
    logic        lane_perm_busy_q;               // 1 while Keccak permutation is actively processing lane block
    logic        lane_first_block_q;             // 1 on first block of sequence (initializes state to 0)
    logic        lane_active_last_q;             // Latched last block indicator during Keccak active round
    logic [255:0] digest_out_q;                  // Registered primary digest output
    logic [255:0] digest_out_sigma_q;            // Registered secondary digest output
    logic         digest_valid_q;                // Registered digest valid flag

    assign digest_out       = digest_out_q;
    assign digest_out_sigma = digest_out_sigma_q;
    assign digest_valid     = digest_valid_q;

    //==============================================================================================
    // Rejection Sampler Filtering and Compaction Pipeline (Stage 1 & Stage 2)
    //==============================================================================================
    // 36-bit Residue Accumulator: Holds 0 to 3 leftover valid 12-bit candidates from previous beat
    logic [35:0] residue_q;
    logic [1:0]  residue_cnt_q;                  // Number of valid residue candidates (0, 1, 2, or 3)
    logic [47:0] stage_data_q;                   // 48-bit registered quartet of valid coefficients ready for pop
    logic        stage_valid_q;                  // 1 when stage_data_q contains 4 valid coefficients

    logic [11:0] cand [0:3];                     // 4 raw candidate values from 48-bit stream word
    logic [3:0]  cand_valid;                     // High if cand[i] < 3329 (rejection test pass)
    logic [11:0] comp_cand [0:3];                // Compacted (left-justified) valid candidates
    logic [2:0]  comp_cnt;                       // Number of valid candidates in current beat (0..4)

    // Stage 1 pipeline registers (decoupling candidate compaction from residue accumulation)
    logic [11:0] pipe_cand_q [0:3];
    logic [2:0]  pipe_cnt_q;
    logic        pipe_valid_q;

    // Decoding helper wires
    wire cmd_is_hash = (cmd_mode == SHA256) || (cmd_mode == SHA512) || (cmd_mode == SHAKE256) || (cmd_mode == SHA512_64);
    wire cmd_sampling_ok = ((cmd_k >= 3'd2) && (cmd_k <= 3'd4)) || ((cmd_mode == VECTOR) && (cmd_k == 3'd1));
    wire is_hash     = is_hash_q;

    // Domain separation padding bytes (FIPS 202 Section 6.1 & 6.2)
    // SHAKE uses 0x1F suffix; SHA3 uses 0x06 suffix
    wire [7:0] dom_byte      = is_shake_q ? 8'h1f : 8'h06;
    wire [7:0] dom_byte_last = is_shake_q ? 8'h9f : 8'h86;

    // Polynomial completion and squeeze triggers
    wire mat_poly_completed = coeff_is_252_q && stage_valid_q;
    wire mat_done_beat;

    // Vector prefetch trigger: initiate Keccak permutation on next polynomial while current one is streaming
    wire vec_prefetch_trig = has_more_polys_q && (
        (fsm_q[S_WAIT0] && core_ready && is_vector_q && !eta3_q) ||
        (fsm_q[S_WAIT_VECTOR1] && eta3_q)
    );

    // Matrix squeeze triggers: squeeze next block if current block exhausted and 256 coefficients not yet found
    wire mat_squeeze = !mat_poly_completed &&
                      ((fsm_q[S_WAIT0] && (block_idx_q == 2'd0) && is_matrix_q) ||
                       (fsm_q[S_MATRIX_MORE] && (block_idx_q < 2'd3)));
    wire mat_restore_trig = !mat_poly_completed && fsm_q[S_MATRIX_MORE] && (block_idx_q == 2'd3);
    wire vec_squeeze = fsm_q[S_WAIT0] && is_vector_q && eta3_q && (block_idx_q == 2'd0);
    wire core_squeeze = core_ready && (mat_squeeze || mat_restore_trig || vec_squeeze);

    //==============================================================================================
    // Fast 64-bit Lane Padding Assembler
    // Assembles 1088-bit Keccak block from 17 x 64-bit lanes with pad10*1 padding
    //==============================================================================================
    logic [1087:0] lane_block_val;
    always_comb begin
        lane_block_val = '0;
        for (integer b = 0; b < 17; b = b + 1) begin
            if (lane_is_last_block_q) begin
                if (b < lane_rem_lanes_q) begin
                    lane_block_val[b*64 +: 64] = absorb_buf_q[b];
                end else if (b == lane_rem_lanes_q && lane_rem_lanes_q < 5'd16) begin
                    lane_block_val[b*64 +: 64] = is_shake_q ? 64'h1f : 64'h06;
                end else if (b == 16) begin
                    if (lane_rem_lanes_q == 5'd16) begin
                        lane_block_val[16*64 +: 64] = is_shake_q ? 64'h8000_0000_0000_001f : 64'h8000_0000_0000_0006;
                    end else begin
                        lane_block_val[16*64 +: 64] = 64'h8000_0000_0000_0000;
                    end
                end else begin
                    lane_block_val[b*64 +: 64] = 64'd0;
                end
            end else begin
                lane_block_val[b*64 +: 64] = absorb_buf_q[b];
            end
        end
    end

    // Core execution triggers
    wire lane_core_trigger = fsm_q[S_LANE_HASH] && lane_block_ready_q && !lane_perm_busy_q && core_ready;
    assign in_lane_ready   = fsm_q[S_LANE_HASH] && !lane_block_ready_q;

    wire is_absorb_trigger = lane_core_trigger || (ENABLE_BYTE_STREAM && (fsm_q[S_HASH_START_FULL] || fsm_q[S_HASH_START_FINAL]));
    assign core_absorb       = is_absorb_trigger;
    assign core_absorb_first = (!ENABLE_BYTE_STREAM || lane_core_trigger) ? lane_first_block_q : hash_first_q;
    assign core_load         = fsm_q[S_START] || vec_prefetch_trig;
    assign core_start        = core_load || core_absorb || core_squeeze;

    //==============================================================================================
    // Keccak-f[1600] 24-Round Permutation Engine Instance
    //==============================================================================================
    keccak_f1600 #(.FAST_24(1)) core (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .load(core_load), .state_in(core_in),
        .absorb(core_absorb), .absorb_first(core_absorb_first),
        .ready(core_ready), .done(core_done), .state_out(core_out)
    );

    assign hash_rate = is_sha512_q ? 8'd72 : 8'd136;
    assign in_ready = fsm_q[S_HASH_ABSORB];

    assign block_load = (fsm_q[S_WAIT0] || fsm_q[S_MATRIX_MORE]) && core_ready;
    assign block_load_vector1 = fsm_q[S_WAIT_VECTOR1];

    //==============================================================================================
    // Matrix Scan Candidate Extraction and Parallel Comparison
    // Extract four 12-bit candidate integers from the 48-bit register
    //==============================================================================================
    assign cand[0] = mat_cand_reg[11:0];
    assign cand[1] = mat_cand_reg[23:12];
    assign cand[2] = mat_cand_reg[35:24];
    assign cand[3] = mat_cand_reg[47:36];

    // Rejection condition: Valid if candidate < 3329 (FIPS 203 Section 4.2.1)
    assign cand_valid[0] = (cand[0] < 12'd3329);
    assign cand_valid[1] = (cand[1] < 12'd3329);
    assign cand_valid[2] = (cand[2] < 12'd3329);
    assign cand_valid[3] = (cand[3] < 12'd3329);

    //==============================================================================================
    // Constant-Depth Candidate Compaction Network
    // Packs 0 to 4 valid candidates left-aligned into comp_cand[0..3]
    //==============================================================================================
    always_comb begin
        comp_cand[0] = 12'd0;
        comp_cand[1] = 12'd0;
        comp_cand[2] = 12'd0;
        comp_cand[3] = 12'd0;
        case ({cand_valid[3], cand_valid[2], cand_valid[1], cand_valid[0]})
            4'b0000: comp_cnt = 3'd0;
            4'b0001: begin comp_cnt = 3'd1; comp_cand[0] = cand[0]; end
            4'b0010: begin comp_cnt = 3'd1; comp_cand[0] = cand[1]; end
            4'b0011: begin comp_cnt = 3'd2; comp_cand[0] = cand[0]; comp_cand[1] = cand[1]; end
            4'b0100: begin comp_cnt = 3'd1; comp_cand[0] = cand[2]; end
            4'b0101: begin comp_cnt = 3'd2; comp_cand[0] = cand[0]; comp_cand[1] = cand[2]; end
            4'b0110: begin comp_cnt = 3'd2; comp_cand[0] = cand[1]; comp_cand[1] = cand[2]; end
            4'b0111: begin comp_cnt = 3'd3; comp_cand[0] = cand[0]; comp_cand[1] = cand[1]; comp_cand[2] = cand[2]; end
            4'b1000: begin comp_cnt = 3'd1; comp_cand[0] = cand[3]; end
            4'b1001: begin comp_cnt = 3'd2; comp_cand[0] = cand[0]; comp_cand[1] = cand[3]; end
            4'b1010: begin comp_cnt = 3'd2; comp_cand[0] = cand[1]; comp_cand[1] = cand[3]; end
            4'b1011: begin comp_cnt = 3'd3; comp_cand[0] = cand[0]; comp_cand[1] = cand[1]; comp_cand[2] = cand[3]; end
            4'b1100: begin comp_cnt = 3'd2; comp_cand[0] = cand[2]; comp_cand[1] = cand[3]; end
            4'b1101: begin comp_cnt = 3'd3; comp_cand[0] = cand[0]; comp_cand[1] = cand[2]; comp_cand[2] = cand[3]; end
            4'b1110: begin comp_cnt = 3'd3; comp_cand[0] = cand[1]; comp_cand[1] = cand[2]; comp_cand[2] = cand[3]; end
            4'b1111: begin comp_cnt = 3'd4; comp_cand[0] = cand[0]; comp_cand[1] = cand[1]; comp_cand[2] = cand[2]; comp_cand[3] = cand[3]; end
        endcase
    end

    //==============================================================================================
    // Decoupled Matrix Pop and Handshake Controls
    //==============================================================================================
    wire in_matrix_state = fsm_q[S_MATRIX_SCAN] || fsm_q[S_MATRIX_MORE] || (fsm_q[S_WAIT0] && is_matrix_q);
    assign mat_out_valid = in_matrix_state && stage_valid_q;
    assign mat_out_data  = stage_data_q;
    wire mat_pop_fire    = mat_out_valid && mat_out_ready;
    assign mat_done_beat = mat_pop_fire && coeff_is_252_q;

    wire stage_can_accept = (!stage_valid_q) || mat_out_ready;
    wire mat_can_scan = fsm_q[S_MATRIX_SCAN] && !mat_poly_completed && stage_can_accept;

    // Compact Streaming Buffer Shift Controls
    wire mat_shift = fsm_q[S_MATRIX_SCAN] && stage_can_accept;
    wire vec_shift = fsm_q[S_VECTOR_SCAN] && vec_out_ready && (eta3_q ? slice_q[0] : (slice_q == 2'd2));
    wire stream_shift = mat_shift || vec_shift;

    //==============================================================================================
    // Compact Streaming Buffer Shift Register Logic (28 x 48-bit words)
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (block_load) begin
            if (is_matrix_q) begin
                // First 48 bits loaded directly into mat_cand_reg; remaining 27 words into stream_buf
                for (integer w = 0; w < 27; w = w + 1) begin
                    stream_buf[w] <= core_out[(w+1)*48 +: 48];
                end
                stream_buf[27] <= 48'd0;
            end else begin
                // Load all 28 words from Keccak permutation output
                for (integer w = 0; w < 28; w = w + 1) begin
                    stream_buf[w] <= core_out[w*48 +: 48];
                end
            end
        end else if (block_load_vector1) begin
            // For eta=3 vector sampling: stitch leftover byte 135 with next 40 bits
            stream_buf[0] <= {core_out[39:0], last_byte_q};
            for (integer w = 1; w < 9; w = w + 1) begin
                stream_buf[w] <= core_out[(w-1)*48 + 40 +: 48];
            end
            stream_buf[9] <= {24'd0, core_out[447:424]};
            for (integer w = 10; w < 28; w = w + 1) begin
                stream_buf[w] <= 48'd0;
            end
        end else if (stream_shift) begin
            // Single-beat left shift
            for (integer w = 0; w < 27; w = w + 1) begin
                stream_buf[w] <= stream_buf[w+1];
            end
            stream_buf[27] <= 48'd0;
        end
    end

    // Preserve byte 135 across Keccak permutation boundaries
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            last_byte_q <= 8'd0;
        end else if (block_load) begin
            last_byte_q <= core_out[1087:1080];
        end
    end

    //==============================================================================================
    // Pipelined Matrix Beat Register
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || fsm_q[S_START] || fsm_q[S_NEXT_POLY]) begin
            mat_cand_reg <= 48'd0;
            mat_beat_q   <= 5'd0;
        end else if ((fsm_q[S_WAIT0] && core_ready && is_matrix_q && !mat_poly_completed) ||
                     (fsm_q[S_MATRIX_MORE] && core_ready && !mat_poly_completed)) begin
            mat_cand_reg <= core_out[47:0];
            mat_beat_q   <= 5'd0;
        end else if (mat_can_scan) begin
            mat_cand_reg <= stream_buf[0];
            if (mat_beat_q != 5'd27) mat_beat_q <= mat_beat_q + 1'b1;
        end
    end

    //==============================================================================================
    // Next CBD Word Pre-decoded Slicing Multiplexer
    //==============================================================================================
    logic [23:0] next_cbd_word;
    always_comb begin
        if (eta3_q) begin
            next_cbd_word = slice_q[0] ? stream_buf[0][47:24] : stream_buf[0][23:0];
        end else begin
            case (slice_q)
                2'd0:    next_cbd_word = {8'b0, stream_buf[0][15:0]};
                2'd1:    next_cbd_word = {8'b0, stream_buf[0][31:16]};
                default: next_cbd_word = {8'b0, stream_buf[0][47:32]};
            endcase
        end
    end

    // Parallel CBD precomputations directly from stream_buf[0] slices
    wire [47:0] cbd_stream_eta2_s0 = calc_cbd_eta2(stream_buf[0][15:0]);
    wire [47:0] cbd_stream_eta2_s1 = calc_cbd_eta2(stream_buf[0][31:16]);
    wire [47:0] cbd_stream_eta2_s2 = calc_cbd_eta2(stream_buf[0][47:32]);

    wire [47:0] cbd_stream_eta3_h0 = calc_cbd_eta3(stream_buf[0][23:0]);
    wire [47:0] cbd_stream_eta3_h1 = calc_cbd_eta3(stream_buf[0][47:24]);

    logic [47:0] next_cbd_data;
    always_comb begin
        if (eta3_q) begin
            next_cbd_data = slice_q[0] ? cbd_stream_eta3_h1 : cbd_stream_eta3_h0;
        end else begin
            case (slice_q)
                2'd0:    next_cbd_data = cbd_stream_eta2_s0;
                2'd1:    next_cbd_data = cbd_stream_eta2_s1;
                default: next_cbd_data = cbd_stream_eta2_s2;
            endcase
        end
    end

    //==============================================================================================
    // Pipelined Vector Scan Word Buffer with Pre-decoded State Counter
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || fsm_q[S_START]) begin
            cbd_word_q <= 24'd0;
            cbd_data_q <= 48'd0;
            slice_q    <= 2'd0;
        end else if (fsm_q[S_WAIT0] && core_ready && !is_matrix_q) begin
            cbd_word_q <= eta3_q ? core_out[23:0] : {8'b0, core_out[15:0]};
            cbd_data_q <= calc_cbd_data(eta3_q ? core_out[23:0] : {8'b0, core_out[15:0]}, eta3_q);
            slice_q    <= 2'd1;
        end else if (fsm_q[S_WAIT_VECTOR1]) begin
            cbd_word_q <= {core_out[15:0], last_byte_q};
            cbd_data_q <= calc_cbd_data({core_out[15:0], last_byte_q}, eta3_q);
            slice_q    <= 2'd1;
        end else if (fsm_q[S_VECTOR_SCAN] && vec_out_ready) begin
            cbd_word_q <= next_cbd_word;
            cbd_data_q <= next_cbd_data;
            if (!eta3_q) begin
                if (slice_q == 2'd2) slice_q <= 2'd0;
                else                 slice_q <= slice_q + 1'b1;
            end else begin
                slice_q[0] <= ~slice_q[0];
                slice_q[1] <= 1'b0;
            end
        end
    end

    wire pipe_clr  = (!rst_n) || fsm_q[S_START] || fsm_q[S_NEXT_POLY];
    wire accum_clr = pipe_clr || (fsm_q[S_WAIT0] && (block_idx_q == 2'd0) && core_ready && is_matrix_q);

    //==============================================================================================
    // Stage 1 Pipeline Registers (Decoupled Candidate Latch)
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (pipe_clr) begin
            pipe_valid_q   <= 1'b0;
            pipe_cnt_q     <= 3'd0;
            pipe_cand_q[0] <= 12'd0;
            pipe_cand_q[1] <= 12'd0;
            pipe_cand_q[2] <= 12'd0;
            pipe_cand_q[3] <= 12'd0;
        end else if (stage_can_accept) begin
            if (mat_can_scan) begin
                pipe_valid_q   <= 1'b1;
                pipe_cnt_q     <= comp_cnt;
                pipe_cand_q    <= comp_cand;
            end else begin
                pipe_valid_q   <= 1'b0;
                pipe_cnt_q     <= 3'd0;
            end
        end
    end

    //==============================================================================================
    // Stage 2: 36-bit Residue Accumulator + 48-bit Staging Register
    // Consolidates up to 3 residual candidates with incoming candidates to form 4-coefficient beats
    //==============================================================================================
    wire [2:0] in_cnt = pipe_valid_q ? pipe_cnt_q : 3'd0;
    wire [3:0] total_avail = {2'b0, residue_cnt_q} + {1'b0, in_cnt};

    // Candidate pool array (stores up to 7 valid candidates: 3 residual + 4 incoming)
    logic [11:0] pool [0:6];
    always_comb begin
        for (integer p = 0; p < 7; p = p + 1) pool[p] = 12'd0;
        case (residue_cnt_q)
            2'd0: begin
                pool[0] = pipe_cand_q[0];
                pool[1] = pipe_cand_q[1];
                pool[2] = pipe_cand_q[2];
                pool[3] = pipe_cand_q[3];
            end
            2'd1: begin
                pool[0] = residue_q[11:0];
                pool[1] = pipe_cand_q[0];
                pool[2] = pipe_cand_q[1];
                pool[3] = pipe_cand_q[2];
                pool[4] = pipe_cand_q[3];
            end
            2'd2: begin
                pool[0] = residue_q[11:0];
                pool[1] = residue_q[23:12];
                pool[2] = pipe_cand_q[0];
                pool[3] = pipe_cand_q[1];
                pool[4] = pipe_cand_q[2];
                pool[5] = pipe_cand_q[3];
            end
            default: begin // 2'd3
                pool[0] = residue_q[11:0];
                pool[1] = residue_q[23:12];
                pool[2] = residue_q[35:24];
                pool[3] = pipe_cand_q[0];
                pool[4] = pipe_cand_q[1];
                pool[5] = pipe_cand_q[2];
                pool[6] = pipe_cand_q[3];
            end
        endcase
    end

    logic [47:0] next_stage_data;
    logic        next_stage_valid;
    logic [35:0] next_residue_data;
    logic [1:0]  next_residue_cnt;

    always_comb begin
        if (stage_can_accept) begin
            if (total_avail >= 4'd4) begin
                // Form a full 4-coefficient output beat (48 bits) and retain residue
                next_stage_data   = {pool[3], pool[2], pool[1], pool[0]};
                next_stage_valid  = 1'b1;
                next_residue_cnt  = 2'(total_avail - 4'd4);
                next_residue_data = {pool[6], pool[5], pool[4]};
            end else begin
                // Insufficient candidates (< 4); store all into residue accumulator
                next_stage_data   = stage_data_q;
                next_stage_valid  = 1'b0;
                next_residue_cnt  = 2'(total_avail);
                next_residue_data = {pool[2], pool[1], pool[0]};
            end
        end else begin
            // Downstream backpressure: preserve staging and residue contents
            next_stage_data   = stage_data_q;
            next_stage_valid  = stage_valid_q;
            next_residue_data = residue_q;
            next_residue_cnt  = residue_cnt_q;
        end
    end

    always_ff @(posedge clk) begin
        if (accum_clr) begin
            stage_data_q  <= 48'd0;
            stage_valid_q <= 1'b0;
            residue_q     <= 36'd0;
            residue_cnt_q <= 2'd0;
        end else begin
            stage_data_q  <= next_stage_data;
            stage_valid_q <= next_stage_valid;
            residue_q     <= next_residue_data;
            residue_cnt_q <= next_residue_cnt;
        end
    end

    //==============================================================================================
    // Decoupled Coefficient Counter and Fast Last-Coeff Flag
    // Counts up to 256 coefficients per polynomial in steps of 4
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (accum_clr) begin
            coeff_q        <= 9'd0;
            coeff_is_252_q <= 1'b0;
        end else if (mat_pop_fire) begin
            coeff_q        <= coeff_q + 9'd4;
            coeff_is_252_q <= (coeff_q == 9'd248);
        end
    end

    //==============================================================================================
    // Decoupled Vector Scan Group Counter (0..63)
    // 64 groups of 4 coefficients = 256 coefficients per polynomial
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || (fsm_q[S_IDLE] && cmd_valid) ||
            (fsm_q[S_WAIT0] && core_ready && !is_matrix_q)) begin
            vec_group_q <= 6'd0;
        end else if (fsm_q[S_WAIT_VECTOR1]) begin
            vec_group_q <= 6'd45;
        end else if (fsm_q[S_VECTOR_SCAN] && vec_out_ready) begin
            if (vec_group_q != 6'd63 && !(eta3_q && (vec_group_q == 6'd44))) begin
                vec_group_q <= vec_group_q + 1'b1;
            end
        end
    end

    //==============================================================================================
    // Merged Single Absorb Buffer Array [0:16] Logic
    // Handles byte-serial input or 64-bit parallel lane input
    //==============================================================================================
    generate
        if (ENABLE_BYTE_STREAM) begin: GEN_BYTE_STREAM
            logic [135:0] hash_sel_q;

            always_ff @(posedge clk) begin
                if (!rst_n) hash_sel_q <= 136'b1;
                else if (fsm_q[S_IDLE] && cmd_valid && cmd_is_hash)
                    hash_sel_q <= 136'b1;
                else if (fsm_q[S_HASH_START_FULL] && core_ready)
                    hash_sel_q <= 136'b1;
                else if (fsm_q[S_HASH_ABSORB] && in_valid && in_keep)
                    hash_sel_q <= {hash_sel_q[134:0], 1'b0};
            end

            for (genvar hb=0; hb<136; hb=hb+1) begin: HASH_BUFFER
                localparam int lane_idx = hb / 8;
                localparam int byte_idx = hb % 8;

                wire last_rate_byte = ((hb == 135) && (mode_q == SHA256 || is_shake_q)) ||
                                       ((hb == 71) && is_sha512_q);
                wire next_byte;
                if (hb == 0) assign next_byte = 1'b0;
                else assign next_byte = hash_sel_q[hb-1] && !((hb == 72) && is_sha512_q);

                assign hash_block[hb*8 +: 8] = absorb_buf_q[lane_idx][byte_idx*8 +: 8];

                wire lane_we = fsm_q[S_LANE_HASH] && in_lane_valid && !lane_block_ready_q && lane_in_sel_q[lane_idx];

                if (hb == 71 || hb == 135) begin: GEN_RATE_BYTE
                    always_ff @(posedge clk) begin
                        if (!rst_n || (fsm_q[S_IDLE] && cmd_valid)) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h00;
                        end else if (lane_we) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= in_lane[byte_idx*8 +: 8];
                        end else if (fsm_q[S_HASH_START_FULL] && core_ready) begin
                            if (hash_final_after_full_q && last_rate_byte)
                                absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h80;
                            else
                                absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h00;
                        end else if (fsm_q[S_HASH_ABSORB] && in_valid) begin
                            if (!in_keep && in_last) begin
                                if (hash_sel_q[hb] && last_rate_byte)
                                    absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= dom_byte_last;
                                else if (hash_sel_q[hb])
                                    absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= dom_byte;
                                else if (last_rate_byte)
                                    absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h80;
                            end else if (in_keep) begin
                                if (hash_sel_q[hb])
                                    absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= in_data;
                                else if (in_last) begin
                                    if (next_byte && last_rate_byte)
                                        absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= dom_byte_last;
                                    else if (next_byte)
                                        absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= dom_byte;
                                    else if (last_rate_byte)
                                        absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h80;
                                end
                            end
                        end
                    end
                end else if (hb == 0) begin: GEN_BYTE_ZERO
                    always_ff @(posedge clk) begin
                        if (!rst_n || (fsm_q[S_IDLE] && cmd_valid)) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h00;
                        end else if (lane_we) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= in_lane[byte_idx*8 +: 8];
                        end else if (fsm_q[S_HASH_START_FULL] && core_ready) begin
                            if (hash_final_after_full_q)
                                absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= dom_byte;
                            else
                                absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h00;
                        end else if (fsm_q[S_HASH_ABSORB] && in_valid) begin
                            if (!in_keep && in_last) begin
                                if (hash_sel_q[hb])
                                    absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= dom_byte;
                            end else if (in_keep) begin
                                if (hash_sel_q[hb])
                                    absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= in_data;
                            end
                        end
                    end
                end else begin: GEN_MID_BYTE
                    wire byte_en = fsm_q[S_HASH_ABSORB] && in_valid && (hash_sel_q[hb] || (in_keep && in_last && next_byte));
                    wire [7:0] byte_d = (hash_sel_q[hb] && in_keep) ? in_data : dom_byte;
                    always_ff @(posedge clk) begin
                        if (!rst_n || (fsm_q[S_IDLE] && cmd_valid) || (fsm_q[S_HASH_START_FULL] && core_ready)) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= 8'h00;
                        end else if (lane_we) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= in_lane[byte_idx*8 +: 8];
                        end else if (byte_en) begin
                            absorb_buf_q[lane_idx][byte_idx*8 +: 8] <= byte_d;
                        end
                    end
                end
            end
        end else begin: NO_BYTE_STREAM
            assign hash_block = 1088'd0;
            for (genvar l=0; l<17; l=l+1) begin: GEN_LANE_NO_BYTE
                always_ff @(posedge clk) begin
                    if (fsm_q[S_LANE_HASH] && in_lane_valid && !lane_block_ready_q && lane_in_sel_q[l]) begin
                        absorb_buf_q[l] <= in_lane;
                    end
                end
            end
        end
    endgenerate

    //==============================================================================================
    // Fast Shallow Keccak Core Initialization Bus
    // Formats 1600-bit state input vector depending on active mode and coordinates
    //==============================================================================================
    logic [7:0] init_byte32, init_byte33;
    always_comb begin
        if (is_sha512_q) begin
            init_byte32 = {5'b0, k_q};
            init_byte33 = 8'h06;
        end else if (is_matrix_q) begin
            if (fsm_q[S_START]) begin
                init_byte32 = transpose_q ? {5'b0, row_q} : {5'b0, col_q};
                init_byte33 = transpose_q ? {5'b0, col_q} : {5'b0, row_q};
            end else begin
                init_byte32 = transpose_q ? {5'b0, next_row_q} : {5'b0, next_col_q};
                init_byte33 = transpose_q ? {5'b0, next_col_q} : {5'b0, next_row_q};
            end
        end else begin
            init_byte32 = fsm_q[S_START] ? vec_poly_nonce_q : vec_poly_nonce_next_q;
            init_byte33 = 8'h1f;
        end
    end

    always_comb begin
        if (core_absorb) begin
            core_in = (!ENABLE_BYTE_STREAM || lane_core_trigger) ?
                      {512'b0, lane_block_val} :
                      {512'b0, hash_block};
        end else begin
            core_in = '0;
            core_in[255:0] = seed_q;
            core_in[32*8 +: 8] = init_byte32;
            core_in[33*8 +: 8] = init_byte33;
            if (is_matrix_q) begin
                core_in[34*8  +: 8] = 8'h1f;
                core_in[167*8 +: 8] = 8'h80;
            end else if (is_sha512_q) begin
                core_in[71*8  +: 8] = 8'h80;
                if (mode_q == SHA512_64) begin
                    core_in[511:256] = seed_hi_q;
                    core_in[64*8 +: 8] = 8'h06;
                end
            end else begin
                core_in[135*8 +: 8] = 8'h80;
            end
        end
    end

    //==============================================================================================
    // Output Multiplexing and Formatting Logic
    //==============================================================================================
    always_comb begin
        out_valid = 1'b0;
        out_data = '0;
        out_count = '0;
        out_last = 1'b0;
        out_poly_index = is_vector_q ? scan_poly_q : poly_q;

        if (ENABLE_BYTE_STREAM && fsm_q[S_HASH_OUT]) begin
            out_valid = 1'b1;
            out_data[7:0] = core_out[hash_idx_q*8 +: 8]; // Directly streamed from Keccak core state
            out_count = 3'd1;
            out_last = is_sha512_q ? (hash_idx_q == 7'd63) : (hash_idx_q == 7'd31);
        end else if (fsm_q[S_VECTOR_SCAN]) begin
            out_valid = 1'b1;
            out_data = cbd_data_q; // Directly driven by boundary register
            out_count = 3'd4;
            out_last = (vec_group_q == 6'd63);
        end else if (in_matrix_state) begin
            if (stage_valid_q) begin
                out_valid = 1'b1;
                out_data = stage_data_q;
                out_count = 3'd4;
                out_last = coeff_is_252_q;
            end
        end
    end

    assign vec_out_valid = fsm_q[S_VECTOR_SCAN];
    assign cmd_ready = fsm_q[S_IDLE];

    wire matrix_done = is_last_matrix_poly_q;

    //==============================================================================================
    // Explicit One-Hot Next-State Combinational Logic
    // Evaluates transitions across the 15 one-hot states
    //==============================================================================================
    always_comb begin
        next_fsm = '0;

        if (fsm_q[S_IDLE]) begin
            if (cmd_valid) begin
                if (in_lane_mode && ((cmd_mode == SHA256) || (cmd_mode == SHAKE256))) next_fsm[S_LANE_HASH] = 1'b1;
                else if (in_lane_mode && ((cmd_mode == SHA512) || (cmd_mode == SHA512_64))) next_fsm[S_START] = 1'b1;
                else if (cmd_is_hash)                         next_fsm[S_HASH_ABSORB] = 1'b1;
                else                                          next_fsm[S_START]     = 1'b1;
            end else begin
                next_fsm[S_IDLE] = 1'b1;
            end
        end

        if (fsm_q[S_LANE_HASH]) begin
            if (lane_perm_busy_q && core_done && lane_active_last_q) begin
                next_fsm[S_IDLE] = 1'b1;
            end else begin
                next_fsm[S_LANE_HASH] = 1'b1;
            end
        end

        if (fsm_q[S_HASH_ABSORB]) begin
            if (in_valid) begin
                if (!in_keep) begin
                    if (in_last) next_fsm[S_HASH_START_FINAL] = 1'b1;
                    else         next_fsm[S_HASH_ABSORB]      = 1'b1;
                end else begin
                    if (hash_last_byte_q) next_fsm[S_HASH_START_FULL]  = 1'b1;
                    else if (in_last)     next_fsm[S_HASH_START_FINAL] = 1'b1;
                    else                  next_fsm[S_HASH_ABSORB]      = 1'b1;
                end
            end else begin
                next_fsm[S_HASH_ABSORB] = 1'b1;
            end
        end

        if (fsm_q[S_HASH_START_FULL]) begin
            if (core_ready) next_fsm[S_HASH_WAIT_FULL]   = 1'b1;
            else            next_fsm[S_HASH_START_FULL]  = 1'b1;
        end

        if (fsm_q[S_HASH_WAIT_FULL]) begin
            if (core_done) begin
                if (hash_final_after_full_q) next_fsm[S_HASH_START_FINAL] = 1'b1;
                else                         next_fsm[S_HASH_ABSORB]      = 1'b1;
            end else begin
                next_fsm[S_HASH_WAIT_FULL] = 1'b1;
            end
        end

        if (fsm_q[S_HASH_START_FINAL]) begin
            if (core_ready) next_fsm[S_HASH_WAIT_FINAL]  = 1'b1;
            else            next_fsm[S_HASH_START_FINAL] = 1'b1;
        end

        if (fsm_q[S_HASH_WAIT_FINAL]) begin
            if (core_done) begin
                if (in_lane_mode && is_sha512_q) next_fsm[S_IDLE]     = 1'b1;
                else                             next_fsm[S_HASH_OUT] = 1'b1;
            end else begin
                next_fsm[S_HASH_WAIT_FINAL] = 1'b1;
            end
        end

        if (fsm_q[S_START]) begin
            if (core_ready) begin
                if (in_lane_mode && is_sha512_q) next_fsm[S_HASH_WAIT_FINAL] = 1'b1;
                else                             next_fsm[S_WAIT0]           = 1'b1;
            end else begin
                next_fsm[S_START] = 1'b1;
            end
        end

        if (fsm_q[S_WAIT0]) begin
            if (is_matrix_q && mat_done_beat) begin
                next_fsm[S_NEXT_POLY] = 1'b1;
            end else if (core_ready) begin
                if (is_matrix_q) next_fsm[S_MATRIX_SCAN] = 1'b1;
                else             next_fsm[S_VECTOR_SCAN] = 1'b1;
            end else begin
                next_fsm[S_WAIT0] = 1'b1;
            end
        end

        if (fsm_q[S_WAIT_VECTOR1]) begin
            next_fsm[S_VECTOR_SCAN] = 1'b1;
        end

        if (fsm_q[S_MATRIX_SCAN]) begin
            if (mat_done_beat) begin
                next_fsm[S_NEXT_POLY] = 1'b1;
            end else if (mat_can_scan && (mat_beat_q == 5'd27)) begin
                next_fsm[S_MATRIX_MORE] = 1'b1;
            end else begin
                next_fsm[S_MATRIX_SCAN] = 1'b1;
            end
        end

        if (fsm_q[S_MATRIX_MORE]) begin
            if (mat_done_beat) begin
                next_fsm[S_NEXT_POLY] = 1'b1;
            end else if (core_ready) begin
                next_fsm[S_MATRIX_SCAN] = 1'b1;
            end else begin
                next_fsm[S_MATRIX_MORE] = 1'b1;
            end
        end

        if (fsm_q[S_VECTOR_SCAN]) begin
            if (vec_out_ready) begin
                if (!eta3_q && (vec_group_q == 6'd63)) begin
                    if (scan_poly_q == {1'b0, k_minus1_q}) next_fsm[S_IDLE]  = 1'b1;
                    else                                   next_fsm[S_WAIT0] = 1'b1;
                end else if (eta3_q && (vec_group_q == 6'd44)) begin
                    next_fsm[S_WAIT_VECTOR1] = 1'b1;
                end else if (eta3_q && (vec_group_q == 6'd63)) begin
                    if (scan_poly_q == {1'b0, k_minus1_q}) next_fsm[S_IDLE]  = 1'b1;
                    else                                   next_fsm[S_WAIT0] = 1'b1;
                end else begin
                    next_fsm[S_VECTOR_SCAN] = 1'b1;
                end
            end else begin
                next_fsm[S_VECTOR_SCAN] = 1'b1;
            end
        end

        if (fsm_q[S_HASH_OUT]) begin
            if (out_ready && ((is_sha512_q && (hash_idx_q == 7'd63)) ||
                              (!is_sha512_q && (hash_idx_q == 7'd31)))) begin
                next_fsm[S_IDLE] = 1'b1;
            end else begin
                next_fsm[S_HASH_OUT] = 1'b1;
            end
        end

        if (fsm_q[S_NEXT_POLY]) begin
            if (matrix_done) begin
                next_fsm[S_IDLE] = 1'b1;
            end else begin
                next_fsm[S_START] = 1'b1;
            end
        end
    end

    //==============================================================================================
    // Unconditional One-Hot State Register Update (Permanent VCC Clock-Enable)
    // Minimizes clock-enable gating delay and routing congestion
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fsm_q         <= '0;
            fsm_q[S_IDLE] <= 1'b1;
        end else begin
            fsm_q <= next_fsm;
        end
    end

    //==============================================================================================
    // Fast Decoupled Lane Input Registers
    //==============================================================================================
    logic [4:0] rem_lanes_minus_1_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rem_lanes_minus_1_q <= 5'd14;
        end else if (cmd_valid) begin
            rem_lanes_minus_1_q <= (cmd_k == 3'd2) ? 5'd14 : (cmd_k == 3'd3) ? 5'd11 : 5'd8;
        end
    end

    logic [4:0] in_rem_minus_1_q;
    always_ff @(posedge clk) begin
        if (!rst_n) in_rem_minus_1_q <= 5'd14;
        else in_rem_minus_1_q <= in_rem_lanes - 5'd1;
    end
    wire lane_is_last_beat = in_last_block ? (lane_in_cnt_q == in_rem_minus_1_q) : lane_in_cnt_q[4];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lane_rem_lanes_q <= 5'd0;
        end else if (fsm_q[S_LANE_HASH] && in_lane_valid && !lane_block_ready_q && in_last_block) begin
            lane_rem_lanes_q <= in_rem_lanes;
        end
    end

    //==============================================================================================
    // Sequential Datapath, Configuration, and Buffer Registers
    //==============================================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mode_q                  <= '0;
            is_matrix_q             <= 1'b0;
            is_vector_q             <= 1'b0;
            is_shake_q              <= 1'b0;
            is_sha512_q             <= 1'b0;
            is_hash_q               <= 1'b0;
            k_q                     <= '0;
            k_minus1_q              <= '0;
            seed_q                  <= '0;
            seed_hi_q               <= '0;
            transpose_q             <= 1'b0;
            eta3_q                  <= 1'b0;
            nonce_q                 <= '0;
            vec_poly_nonce_q        <= '0;
            vec_poly_nonce_next_q   <= '0;
            row_q                   <= '0;
            col_q                   <= '0;
            next_row_q              <= '0;
            next_col_q              <= (cmd_k > 3'd1) ? 3'd1 : 3'd0;
            has_more_matrix_polys_q <= 1'b0;
            is_last_matrix_poly_q   <= 1'b0;
            poly_q                  <= '0;
            scan_poly_q             <= '0;
            hash_idx_q              <= '0;
            hash_pos_q              <= '0;
            hash_count_q            <= '0;
            hash_last_byte_q        <= 1'b0;
            hash_first_q            <= 1'b1;
            hash_final_after_full_q <= 1'b0;
            block_idx_q             <= '0;
            has_more_polys_q        <= (cmd_k > 3'd1);
            start_at_wait0_q        <= 1'b0;
            cmd_done                <= 1'b0;

            // Lane buffer control reset
            lane_first_block_q      <= 1'b1;
            lane_in_cnt_q           <= 5'd0;
            lane_in_sel_q           <= 17'd1;
            lane_block_ready_q      <= 1'b0;
            lane_is_last_block_q    <= 1'b0;
            lane_perm_busy_q        <= 1'b0;
            lane_active_last_q      <= 1'b0;
            digest_out_q            <= 256'd0;
            digest_out_sigma_q      <= 256'd0;
            digest_valid_q          <= 1'b0;
        end else begin
            cmd_done <= 1'b0;

            // Command Latch Phase
            if (fsm_q[S_IDLE] && cmd_valid) begin
                mode_q                  <= cmd_mode;
                is_matrix_q             <= (cmd_mode == MATRIX);
                is_vector_q             <= (cmd_mode == VECTOR);
                is_shake_q              <= (cmd_mode == SHAKE256);
                is_sha512_q             <= (cmd_mode == SHA512) || (cmd_mode == SHA512_64);
                is_hash_q               <= cmd_is_hash;
                k_q                     <= cmd_k;
                k_minus1_q              <= cmd_k - 1'b1;
                seed_q                  <= cmd_seed;
                seed_hi_q               <= cmd_seed_hi;
                transpose_q             <= cmd_transpose;
                eta3_q                  <= cmd_eta3;
                nonce_q                 <= cmd_nonce;
                vec_poly_nonce_q        <= cmd_nonce;
                vec_poly_nonce_next_q   <= cmd_nonce + 8'd1;
                row_q                   <= '0;
                col_q                   <= '0;
                next_row_q              <= '0;
                next_col_q              <= (cmd_k > 3'd1) ? 3'd1 : 3'd0;
                has_more_matrix_polys_q <= (cmd_mode == MATRIX) && (cmd_k > 3'd1);
                is_last_matrix_poly_q   <= (cmd_mode == MATRIX) && (cmd_k == 3'd1);
                poly_q                  <= '0;
                scan_poly_q             <= '0;
                block_idx_q             <= '0;
                has_more_polys_q        <= (cmd_k > 3'd1);
                start_at_wait0_q        <= 1'b0;
                digest_valid_q          <= 1'b0;

                if (cmd_is_hash) begin
                    hash_pos_q              <= '0;
                    hash_count_q            <= (cmd_mode == SHA512) ? 8'd71 : 8'd135;
                    hash_last_byte_q        <= 1'b0;
                    hash_first_q            <= 1'b1;
                    hash_final_after_full_q <= 1'b0;
                end
            end

            // 64-bit Lane Absorb Sequencing
            if (fsm_q[S_LANE_HASH]) begin
                if (lane_block_ready_q) begin
                    lane_in_cnt_q <= 5'd0;
                    lane_in_sel_q <= 17'd1;
                end else if (in_lane_valid) begin
                    if (lane_is_last_beat) begin
                        lane_block_ready_q   <= 1'b1;
                        lane_is_last_block_q <= in_last_block;
                    end else begin
                        lane_in_cnt_q        <= lane_in_cnt_q + 1'b1;
                        lane_in_sel_q        <= {lane_in_sel_q[15:0], 1'b0};
                    end
                end

                if (lane_core_trigger) begin
                    lane_perm_busy_q     <= 1'b1;
                    lane_block_ready_q   <= 1'b0;
                    lane_first_block_q   <= 1'b0;
                    lane_active_last_q   <= lane_is_last_block_q;
                end

                if (lane_perm_busy_q && core_done) begin
                    lane_perm_busy_q <= 1'b0;
                    if (lane_active_last_q) begin
                        digest_out_q         <= core_out[255:0];
                        digest_valid_q       <= 1'b1;
                        cmd_done             <= 1'b1;
                        lane_first_block_q   <= 1'b1;
                        lane_in_cnt_q        <= 5'd0;
                        lane_in_sel_q        <= 17'd1;
                        lane_block_ready_q   <= 1'b0;
                        lane_is_last_block_q <= 1'b0;
                        lane_active_last_q   <= 1'b0;
                    end
                end
            end

            // Byte-Serial Message Absorption
            if (fsm_q[S_HASH_ABSORB] && in_valid) begin
                if (in_keep) begin
                    if (!hash_last_byte_q && !in_last) begin
                        hash_count_q     <= hash_count_q - 1'b1;
                        hash_pos_q       <= hash_pos_q + 1'b1;
                        hash_last_byte_q <= (hash_count_q == 8'd1);
                    end else if (hash_last_byte_q) begin
                        hash_final_after_full_q <= in_last;
                    end
                end
            end

            if (fsm_q[S_HASH_WAIT_FULL] && core_done) begin
                hash_first_q     <= 1'b0;
                hash_pos_q       <= '0;
                hash_count_q     <= is_sha512_q ? 8'd71 : 8'd135;
                hash_last_byte_q <= 1'b0;
            end

            if (fsm_q[S_HASH_WAIT_FINAL] && core_done) begin
                if (in_lane_mode && is_sha512_q) begin
                    digest_out_q       <= core_out[255:0];
                    digest_out_sigma_q <= core_out[511:256];
                    digest_valid_q     <= 1'b1;
                    cmd_done           <= 1'b1;
                end else if (ENABLE_BYTE_STREAM) begin
                    hash_idx_q <= '0;
                end
            end

            // Start of Matrix / Vector Permutation
            if (fsm_q[S_START] && core_ready) begin
                block_idx_q <= 2'd0;
                if (in_lane_mode && is_sha512_q) begin
                    start_at_wait0_q <= 1'b0;
                end else begin
                    start_at_wait0_q <= is_matrix_q || (eta3_q ? 1'b1 : has_more_polys_q);
                end
            end

            // Wait Phase for Block 0
            if (fsm_q[S_WAIT0] && core_ready) begin
                start_at_wait0_q <= 1'b0;
                if (is_matrix_q) begin
                    if (!mat_poly_completed && (block_idx_q == 2'd0)) begin
                        block_idx_q <= 2'd1;
                    end
                end else begin
                    if (!eta3_q && has_more_polys_q) begin
                        poly_q                <= poly_q + 1'b1;
                        vec_poly_nonce_q      <= vec_poly_nonce_next_q;
                        vec_poly_nonce_next_q <= vec_poly_nonce_next_q + 8'd1;
                        has_more_polys_q      <= (poly_q + 1'b1 < {1'b0, k_minus1_q});
                    end
                end
            end

            // Wait Phase for Block 1 (eta=3 Vector Sampling)
            if (fsm_q[S_WAIT_VECTOR1]) begin
                if (has_more_polys_q) begin
                    poly_q                <= poly_q + 1'b1;
                    vec_poly_nonce_q      <= vec_poly_nonce_next_q;
                    vec_poly_nonce_next_q <= vec_poly_nonce_next_q + 8'd1;
                    has_more_polys_q      <= (poly_q + 1'b1 < {1'b0, k_minus1_q});
                end
            end

            // Matrix Squeeze Progress Tracking
            if (fsm_q[S_MATRIX_MORE] && core_ready && !mat_poly_completed) begin
                if (block_idx_q != 2'd3) begin
                    block_idx_q <= block_idx_q + 1'b1;
                end
            end

            // Vector Output Progress Tracking
            if (fsm_q[S_VECTOR_SCAN] && vec_out_ready) begin
                if (!eta3_q && (vec_group_q == 6'd63)) begin
                    scan_poly_q <= scan_poly_q + 1'b1;
                    if (scan_poly_q == {1'b0, k_minus1_q}) begin
                        cmd_done <= 1'b1;
                    end else begin
                        start_at_wait0_q <= has_more_polys_q;
                    end
                end else if (eta3_q && (vec_group_q == 6'd44)) begin
                    // Waiting for vector part 2
                end else if (eta3_q && (vec_group_q == 6'd63)) begin
                    scan_poly_q <= scan_poly_q + 1'b1;
                    if (scan_poly_q == {1'b0, k_minus1_q}) begin
                        cmd_done <= 1'b1;
                    end else begin
                        start_at_wait0_q <= 1'b1;
                    end
                end
            end

            // Stream Hash Digests Directly from Core State Output
            if (ENABLE_BYTE_STREAM && fsm_q[S_HASH_OUT] && out_ready) begin
                if ((is_sha512_q && (hash_idx_q == 7'd63)) ||
                    (!is_sha512_q && (hash_idx_q == 7'd31))) begin
                    cmd_done <= 1'b1;
                end else begin
                    hash_idx_q <= hash_idx_q + 1'b1;
                end
            end

            // Advance Polynomial Coordinates (Row/Column Update for Matrix A)
            if (fsm_q[S_NEXT_POLY]) begin
                if (matrix_done) begin
                    cmd_done              <= 1'b1;
                    is_last_matrix_poly_q <= 1'b0;
                end else begin
                    logic [2:0] upd_col, upd_row;
                    logic [2:0] fut_col, fut_row;

                    scan_poly_q <= scan_poly_q + 1'b1;
                    poly_q      <= poly_q + 1'b1;

                    // Row-major traversal of public matrix A[row, col]
                    if (col_q == k_minus1_q) begin
                        upd_col = 3'd0;
                        upd_row = row_q + 1'b1;
                    end else begin
                        upd_col = col_q + 1'b1;
                        upd_row = row_q;
                    end

                    // Lookahead calculation for prefetching
                    if (upd_col == k_minus1_q) begin
                        fut_col = 3'd0;
                        fut_row = upd_row + 1'b1;
                    end else begin
                        fut_col = upd_col + 1'b1;
                        fut_row = upd_row;
                    end

                    col_q      <= upd_col;
                    row_q      <= upd_row;
                    next_col_q <= fut_col;
                    next_row_q <= fut_row;
                    has_more_matrix_polys_q <= !((upd_row == k_minus1_q) && (upd_col == k_minus1_q));
                    is_last_matrix_poly_q   <= ((upd_row == k_minus1_q) && (upd_col == k_minus1_q));
                end
            end
        end
    end
endmodule
