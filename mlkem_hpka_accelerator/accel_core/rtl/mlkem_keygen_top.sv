`timescale 1ns/1ps

// =============================================================================
// Module Name:    mlkem_keygen_top
// Project:        ML-KEM High-Performance Post-Quantum Cryptographic Accelerator
// Specification:  NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Standard Modes: ML-KEM-512 (k=2, Security Category 1)
//                 ML-KEM-768 (k=3, Security Category 3)
//                 ML-KEM-1024 (k=4, Security Category 5)
// Operations:     Mode 0: Key Generation (ML-KEM.KeyGen - Algorithm 16)
//                 Mode 1: Encapsulation  (ML-KEM.Encaps  - Algorithm 17)
//                 Mode 2: Decapsulation  (ML-KEM.Decaps  - Algorithm 18)
// Target Devices: AMD Xilinx UltraScale+, Versal Prime/AI, and ASIC implementations
// =============================================================================
// ARCHITECTURAL DESIGN & HARDWARE SPECIFICATION:
// -----------------------------------------------------------------------------
// 1. UNIFIED MULTI-OPERATION MASTER ACCELERATOR:
//    Provides a single monolithic, multi-mode post-quantum cryptographic accelerator
//    capable of executing KeyGen, Encapsulation, and Decapsulation across all three
//    NIST FIPS 203 parameter sets (k in {2, 3, 4}). Subordinate operation engines
//    (`mlkem_encap_datapath.svh` and `mlkem_decap_datapath.svh`) bind directly to
//    shared arithmetic and memory datapaths inside this top-level module, minimizing
//    redundancy and area while maximizing throughput.
//
// 2. ZERO-BRAM ARCHITECTURE (100% DISTRIBUTED RAM / LUTRAM):
//    The accelerator achieves complete zero Block RAM (0 BRAM / 0 URAM) resource
//    utilization. All coefficient buffers, polynomial vectors (s, e, t, r, e1, e2,
//    u, v), and intermediate accumulation structures reside entirely in distributed
//    LUTRAM (Xilinx SLICEM RAM64M / RAM32M primitives):
//    - Single-cycle, zero-wait-state synchronous write and asynchronous/synchronous read.
//    - Eliminates pipeline dead cycles and BRAM read latency stalls.
//    - 4-bank independent partitioning of s and pk prevents cross-port multiplexing
//      congestion and enables parallel reads by NTT, multiplier, and SHA engines.
//
// 3. STRICTLY 8-DSP MODULAR ARITHMETIC ALLOCATION:
//    The entire accelerator consumes exactly 8 DSP slices across all modes of operation,
//    strictly confined to `mlkem_mul_stream`. These 8 DSPs implement 4 parallel SIMD
//    lanes of Barrett/Montgomery polynomial pointwise multiplication (2 DSPs per
//    lane), computing 4 modular products per clock cycle over GF(q=3329).
//
// 4. SHARED SUBMODULE INTEGRATION:
//    - `mlkem_hash_sampler`: Unified symmetric cryptographic engine (Keccak-f[1600])
//      supporting SHA3-256, SHA3-512, SHAKE128 (SampleNTT matrix sampler), and
//      SHAKE256 (SamplePolyCBD noise sampler) with fast 64-bit absorption lanes.
//    - `mlkem_ntt_intt`: High-throughput forward and inverse Number Theoretic
//      Transform core over Z_q[X]/(X^256 + 1) with dual-butterfly datapath.
//    - `mlkem_mul_stream`: 8-DSP streaming pointwise Montgomery multiplier.
//    - Pipeline Accumulators: 4-stage modular accumulator pipeline computing
//      t = A*s + e (KeyGen), u = A^T*r + e1, and v = t^T*r + e2 + Decompress(m) (Encap).
//
// 5. MASTER FSM STATE FLOW:
//    - ST_IDLE             (4'd0): Awaiting start command; latches mode, k, seeds.
//    - ST_SHA512_WAIT      (4'd1): Expand 32-byte seed d -> (rho, sigma) via SHA3-512.
//    - ST_START_NTT        (4'd2): Kick off forward NTT pipeline and trigger vector s sampling.
//    - ST_SAMPLE_S         (4'd3): Sample secret vector s via SHAKE256 CBD, forward to NTT,
//                                  and store NTT(s) into banked distributed RAM (ram_s_b0..b3).
//    - ST_SAMPLE_E         (4'd4): Sample error vector e via SHAKE256 CBD directly into ram_e.
//    - ST_SAMPLE_A_AND_MUL (4'd5): On-the-fly matrix A sampling from rho via SHAKE128,
//                                  streamed into 8-DSP multiplier with s, accumulated in
//                                  ram_t, and added to e to construct public key t.
//    - ST_FINISH_EK_HASH   (4'd6): Stream public key t and rho through SHA3-256 to compute H(ek).
//    - ST_DONE             (4'd7): Assert done and ready; retain keys; support instant restart.
//    - ST_ENCAP            (4'd8): Delegate control to encapsulation datapath (`mlkem_encap_datapath.svh`).
//    - ST_DECAP            (4'd9): Delegate control to decapsulation datapath (`mlkem_decap_datapath.svh`).
//
// 6. EXTERNAL INTERFACES & DIAGNOSTICS:
//    - Command & Control: start, ready, done, operation_error, mode, k.
//    - High-Speed Streaming: 64-bit lane key ingress (ek_in, dk_in), 88-bit ciphertext
//      transfer (ct_in, ct_out) with low-byte-first canonical packing.
//    - Memory Query Interface: 1-cycle synchronous byte readout for public/private keys,
//      retained ciphertext, and established shared secret.
//    - Cycle Profiling: 32-bit cycle counter (`cycle_cnt`) tracking execution latency.
// =============================================================================

module mlkem_keygen_top (
    // -------------------------------------------------------------------------
    // Clock and Global Reset
    // -------------------------------------------------------------------------
    input  logic         clk,        // Primary system clock
    input  logic         rst_n,      // Active-low global asynchronous/synchronous reset

    // -------------------------------------------------------------------------
    // Command & Configuration Interface
    // -------------------------------------------------------------------------
    input  logic         start,      // Command start strobe; accepted when ready is asserted
    output logic         ready,      // Accelerator idle / ready to accept new command
    output logic         done,       // Command completion pulse / level indicator
    input  logic [2:0]   k,          // Security level parameter: 2: ML-KEM-512, 3: ML-KEM-768, 4: ML-KEM-1024
    input  logic [255:0] seed_d,     // 32-byte input seed d (KeyGen entropy source)
    input  logic [255:0] seed_z,     // 32-byte input seed z (Decap implicit rejection seed)

    // -------------------------------------------------------------------------
    // Operational Mode & Message Injection
    // -------------------------------------------------------------------------
    // 0: KeyGen, 1: Encapsulation, 2: Decapsulation; latched on (start && ready).
    input  logic [1:0]   mode = 2'd0,
    input  logic [255:0] enc_message = 256'd0, // 32-byte message m for Encapsulation testing

    // -------------------------------------------------------------------------
    // Encapsulation Key (ek) Streaming Input Interface
    // -------------------------------------------------------------------------
    // Encapsulation key: little-endian 64-bit lanes, including final rho.
    // Transfer starts AFTER command acceptance and is included in cycle_cnt.
    input  logic         ek_in_valid = 1'b0, // Public key streaming valid
    output logic         ek_in_ready,        // Public key streaming backpressure ready
    input  logic [63:0]  ek_in_data = 64'd0, // Public key 64-bit data lane
    input  logic         ek_in_last = 1'b0,  // Final 64-bit lane indicator of ek

    // -------------------------------------------------------------------------
    // Decapsulation Key (dk) Streaming Input Interface
    // -------------------------------------------------------------------------
    // Complete standard dk, little-endian 64-bit lanes, independent of ct.
    input  logic         dk_in_valid = 1'b0, // Decapsulation secret key streaming valid
    output logic         dk_in_ready,        // Decapsulation secret key backpressure ready
    input  logic [63:0]  dk_in_data = 64'd0, // Decapsulation secret key 64-bit data lane
    input  logic         dk_in_last = 1'b0,  // Final 64-bit lane indicator of dk

    // -------------------------------------------------------------------------
    // Ciphertext (ct) Streaming Input Interface (Decapsulation)
    // -------------------------------------------------------------------------
    // Same eight-coefficient byte groups as ct_out, including final v group.
    input  logic         ct_in_valid = 1'b0, // Ingress ciphertext group valid
    output logic         ct_in_ready,        // Ingress ciphertext backpressure ready
    input  logic [87:0]  ct_in_data = 88'd0, // Ingress compressed ciphertext payload
    input  logic [3:0]   ct_in_bytes = 4'd0, // Valid byte count in current ciphertext group
    input  logic         ct_in_last = 1'b0,  // Final ciphertext group indicator
    output logic         operation_error,    // Error flag: non-canonical coeffs, bad framing, invalid k
    output logic [255:0] shared_secret,      // 256-bit established shared key (K or implicit rejection K)

    // -------------------------------------------------------------------------
    // Ciphertext (ct) Streaming Output Interface (Encapsulation)
    // -------------------------------------------------------------------------
    // Eight compressed coefficients per group, low byte first. No backpressure:
    // ciphertext is also retained for random-access readout after completion.
    output logic         ct_out_valid,       // Egress ciphertext group valid
    output logic [87:0]  ct_out_data,        // Egress compressed ciphertext payload
    output logic [3:0]   ct_out_bytes,       // Valid byte count in egress group
    output logic         ct_out_last,        // Final ciphertext group marker

    // -------------------------------------------------------------------------
    // Latency Profiling
    // -------------------------------------------------------------------------
    output logic [31:0]  cycle_cnt,          // 32-bit execution cycle counter

    // -------------------------------------------------------------------------
    // Memory Query Interface (1-Cycle Synchronous Latency)
    // -------------------------------------------------------------------------
    input  logic         mem_rd_en,          // Memory read enable strobe
    input  logic         mem_rd_is_dk,       // Read target selector: 0: ek / ct, 1: dk / ss
    input  logic [11:0]  mem_rd_addr,        // Byte address within selected key/artifact
    output logic [7:0]   mem_rd_data,        // Synchronous read data byte
    output logic         mem_rd_valid,       // Read data valid flag (asserted 1 cycle after mem_rd_en)

    // -------------------------------------------------------------------------
    // Streaming Key Out Interface
    // -------------------------------------------------------------------------
    output logic         key_out_valid,      // Streaming key output valid
    output logic [7:0]   key_out_data,       // Streaming key output data byte
    output logic         key_out_last,       // Final byte indicator of streaming key
    output logic         key_out_is_dk       // Key identity flag: 0: ek, 1: dk
);

    // =========================================================================
    // 1. Parameters and Type Definitions
    // =========================================================================
    // Prime modulus Q = 3329 as specified in FIPS 203 Section 2.1
    localparam logic [11:0] Q = 12'd3329;

    // Master KeyGen FSM State Enumeration
    typedef enum logic [3:0] {
        ST_IDLE              = 4'd0, // Awaiting start command; latch parameters
        ST_SHA512_WAIT       = 4'd1, // Awaiting SHA3-512 expansion of seed d into (rho, sigma)
        ST_START_NTT         = 4'd2, // Initialize forward NTT and launch vector s CBD sampler
        ST_SAMPLE_S          = 4'd3, // Sample secret vector s, feed through NTT, write ram_s
        ST_SAMPLE_E          = 4'd4, // Sample error vector e via CBD directly into ram_e
        ST_SAMPLE_A_AND_MUL  = 4'd5, // Sample matrix A, stream into 8-DSP mul with s, add e
        ST_FINISH_EK_HASH    = 4'd6, // Hash public key t concatenated with rho: H(ek) via SHA3-256
        ST_DONE              = 4'd7, // KeyGen/Encap/Decap complete; outputs valid
        ST_ENCAP             = 4'd8, // Encapsulation active; delegate to encap datapath
        ST_DECAP             = 4'd9  // Decapsulation active; delegate to decap datapath
    } fsm_state_t;

    fsm_state_t fsm_q;               // Current master FSM state register
    logic       fsm_sample_a_q;      // Registered flag: actively in ST_SAMPLE_A_AND_MUL
    logic [1:0] mode_q;              // Latched operational mode (0: KeyGen, 1: Encap, 2: Decap)

    // Decapsulation Datapath Interconnect Wires
    wire dec_compute, dec_kick, dec_fail;
    wire dec_n_cmd, dec_n_inverse, dec_n_valid, dec_n_last;
    wire [4:0] dec_n_polys;
    wire [3:0] dec_n_poly;
    wire [23:0] dec_n_data;
    wire dec_mul_valid, dec_mul_start, dec_mul_reset;
    wire [47:0] dec_mul_a, dec_mul_b;
    wire dec_s_cmd, dec_lane_valid, dec_lane_last;
    wire [2:0] dec_s_mode;
    wire [63:0] dec_lane;
    wire [4:0] dec_rem_lanes;
    wire dec_sk_write, dec_u_write, dec_v_write, dec_pk_write;
    wire [7:0] dec_sk_addr, dec_u_addr;
    wire [5:0] dec_v_addr;
    wire [47:0] dec_sk_data, dec_u_data, dec_v_data;
    wire [255:0] dec_message, dec_h, dec_rho, dec_reject;
    wire dec_mismatch;
    wire [23:0] dec_v_pair;
    logic [7:0] dec_ct_groups_q;
    wire [47:0] dec_feed_word, enc_product_word;
    logic [8:0] dec_mul_word_q;
    logic [8:0] feed_word_addr_q;
    wire  [8:0] dec_feed_word_q = feed_word_addr_q;
    logic [6:0] dec_feed_pair_q;
    logic [6:0] dec_result_pair_q;
    logic [7:0] dec_pack_group_q;
    wire [87:0] dec_compare_word;

    // Encapsulation Datapath Activity Tracking
    wire enc_complete;
    logic enc_active_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enc_active_q <= 1'b0;
        end else if (start && ready) begin
            enc_active_q <= (mode != 2'd0);
        end else if (enc_complete || (fsm_q == ST_DONE)) begin
            enc_active_q <= 1'b0;
        end
    end
    wire enc_active = enc_active_q;
    wire enc_start = start && ready && mode != 0;
    wire enc_abort, enc_inverse, enc_lane_valid, enc_lane_last_block;
    logic enc_sub_rst_n_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            enc_sub_rst_n_q <= 1'b0;
        else
            enc_sub_rst_n_q <= !enc_abort;
    end

    // Encapsulation Datapath Interconnect Wires
    logic enc_s_cmd_valid, enc_s_eta3;
    logic [2:0] enc_s_mode, enc_s_k;
    logic [7:0] enc_s_nonce;
    logic [255:0] enc_s_seed, enc_h_q;
    wire enc_n_cmd_valid, enc_n_valid, enc_n_last;
    wire [4:0] enc_n_polys;
    wire [23:0] enc_n_data;
    wire [3:0] enc_n_poly;
    wire enc_mul_rst, enc_mul_valid, enc_result_ready;
    wire [47:0] enc_mul_b;
    logic [47:0] enc_pk_mul_word;
    logic [5:0]  enc_pk_group_q;
    logic        enc_is_v_q;
    logic [5:0] enc_mul_beat_q;
    logic       enc_mul_start_q;
    wire enc_mat_ready, enc_mat_req_ready, enc_out_ready, enc_e1_write, enc_r_write, enc_pk_write;
    logic [5:0] enc_sample_beat_q;
    logic [2:0] enc_feed_poly_q, enc_mul_col_q;
    logic [6:0] enc_feed_pair_q, enc_result_pair_q;
    wire  [8:0] enc_feed_word_q = feed_word_addr_q;
    logic [8:0] enc_pk_word_q;
    wire [47:0] enc_pk_word;
    logic [7:0] enc_read_byte;

    // =========================================================================
    // 2. Storage Registers and Unified Distributed RAMs
    // =========================================================================
    logic [255:0] seed_d_q;          // Latched 32-byte seed d
    logic [255:0] seed_z_q;          // Latched 32-byte seed z
    (* max_fanout = 16 *) logic [2:0] k_q; // Latched security level k (fanout limited for timing closure)
    logic         k_invalid_q;       // Asserted if k < 2 or k > 4
    logic [255:0] rho_q;             // 32-byte public matrix seed rho (from SHA3-512(d))
    logic [255:0] sigma_q;           // 32-byte secret noise seed sigma (from SHA3-512(d))
    logic [255:0] h_ek_q;            // 32-byte public key digest H(ek) = SHA3-256(ek)
    logic [7:0]   t_lanes_total_q;   // Total 64-bit lanes comprising vector t

    // Distributed RAM buffers (0 BRAM Architecture)
    // - 4 coefficients packed per 48-bit word (12 bits per coefficient)
    // - 64 words per polynomial (64 * 4 = 256 coefficients per ring element)
    // - 4 explicit 64-entry banks to prevent interslice read-modify-write data multiplexing
    (* ram_style = "distributed" *) logic [47:0] ram_s_b0 [0:63]; // Post-NTT secret vector s Bank 0
    (* ram_style = "distributed" *) logic [47:0] ram_s_b1 [0:63]; // Post-NTT secret vector s Bank 1
    (* ram_style = "distributed" *) logic [47:0] ram_s_b2 [0:63]; // Post-NTT secret vector s Bank 2
    (* ram_style = "distributed" *) logic [47:0] ram_s_b3 [0:63]; // Post-NTT secret vector s Bank 3

    (* ram_style = "distributed" *) logic [47:0] ram_e  [0:255]; // Post-NTT error vector e (up to 4 polys = 256 words)

    // Declarations for unified read data wires
    wire [47:0] ram_s_query_rdata;   // Read data for NTT feeding
    wire [47:0] s_word_read;         // Read data for matrix-vector multiplier
    wire [47:0] ram_s_dk_rdata;      // Read data for host memory query readout

    // 4-Banked distributed RAM for public key t: 4 banks x 64 words (eliminates 5-read-port replication)
    (* ram_style = "distributed" *) logic [47:0] ram_pk_b0 [0:63]; // Public key polynomial t Bank 0
    (* ram_style = "distributed" *) logic [47:0] ram_pk_b1 [0:63]; // Public key polynomial t Bank 1
    (* ram_style = "distributed" *) logic [47:0] ram_pk_b2 [0:63]; // Public key polynomial t Bank 2
    (* ram_style = "distributed" *) logic [47:0] ram_pk_b3 [0:63]; // Public key polynomial t Bank 3

    wire [47:0] sha_w0, sha_w1, sha_w2, sha_w3; // SHA engine read ports
    wire [47:0] q_w0, q_w1, q_w2, q_w3;         // Host memory query read ports

    (* ram_style = "distributed" *) logic [47:0] ram_t  [0:63];  // Row accumulator buffer (64 words = 256 coefficients)

    logic [3:0] s_ready_mask_q;  // Bitmask tracking which polynomials of s are fully transformed in ram_s
    logic [3:0] e_ready_mask_q;  // Bitmask tracking which polynomials of e are fully transformed in ram_e
    logic       col_s_ready_q;   // Registered status: is polynomial s for the active matrix column ready?

    // Multiplier accumulation tracking registers
    logic [2:0] accum_row_q;         // Active matrix row index being accumulated
    logic [2:0] accum_col_q;         // Active matrix column index being multiplied
    logic [5:0] accum_beat_q;        // Word beat index within active polynomial (0..63)
    logic       is_last_col_q;       // Flag: active column is the final column (k - 1)
    logic       accum_row_lt_k_q;    // Flag: active row < k
    logic       accum_row_is_last_q; // Flag: active row is the final row (k - 1)

    // Matrix coordinates during sampling
    logic [5:0] mat_beat_q;          // Word beat index within sampled matrix entry (0..63)
    logic [2:0] mat_row_q;           // Row coordinate of matrix entry A[row][col]
    logic [2:0] mat_col_q;           // Column coordinate of matrix entry A[row][col]

    // Cycle counter logic
    logic [31:0] cycle_cnt_q;
    assign cycle_cnt = cycle_cnt_q;

    // Memory query address calculations
    logic [11:0] rd_addr_q;
    logic        rd_is_dk_q;
    logic        rd_en_q;

    // Byte length calculations: pke_bytes = k * 384 bytes, ek_total_bytes = k * 384 + 32 bytes
    wire [11:0] pke_bytes      = {k_q, 7'b0} + {k_q, 8'b0}; // k * 384 = k * 128 * 3
    wire [11:0] ek_total_bytes = pke_bytes + 12'd32;

    // Fast reciprocal division by 6 function for 12-bit addresses
    // Computes floor(a / 6) via fixed-point multiplication: (a * 0xAAAB) >> 18
    // Decomposed into shift-and-add terms: {a, 13'b0} + {a, 11'b0} + ... + a
    function automatic logic [7:0] div6_12b(input logic [11:0] a);
        logic [25:0] p;
        p = {a, 13'b0} + {a, 11'b0} + {a, 9'b0} + {a, 7'b0} + {a, 5'b0} + {a, 3'b0} + {a, 1'b0} + a;
        div6_12b = p[23:16];
    endfunction

    // Address translation for secret key and public key byte reads
    wire [7:0] dk_s_word = div6_12b(rd_addr_q);
    wire [2:0] dk_s_sub  = rd_addr_q - ({dk_s_word, 2'b0} + {dk_s_word, 1'b0});

    wire [11:0] addr_in_pk = rd_is_dk_q ? (rd_addr_q - pke_bytes) : rd_addr_q;
    wire [7:0]  ek_t_word  = div6_12b(addr_in_pk);
    wire [2:0]  ek_t_sub   = addr_in_pk - ({ek_t_word, 2'b0} + {ek_t_word, 1'b0});

    // =========================================================================
    // 3. Submodule Interconnect Wires
    // =========================================================================

    // A. mlkem_hash_sampler Wires & Instantiation
    // Unified symmetric cryptography engine executing Keccak-f[1600] for SHA3 and SHAKE
    logic        sampler_cmd_valid;
    logic        sampler_cmd_ready;
    logic [2:0]  sampler_cmd_mode;
    logic [2:0]  sampler_cmd_k;
    logic [255:0] sampler_cmd_seed;
    logic        sampler_cmd_transpose;
    logic        sampler_cmd_eta3;
    logic [7:0]  sampler_cmd_nonce;

    logic        sampler_in_ready;

    // Fast 64-bit Lane Absorb & Direct SHA Wires
    wire         sampler_in_lane_mode = 1'b1; // Always enable fast hardware acceleration paths
    logic        sampler_in_lane_valid;
    logic        sampler_in_lane_ready;
    logic [63:0] sampler_in_lane;
    logic        sampler_in_last_block;
    logic [4:0]  sampler_in_rem_lanes;
    logic        sampler_digest_valid;
    logic [255:0] sampler_digest_out;
    logic [255:0] sampler_digest_out_sigma;

    logic        sampler_out_valid;
    logic        sampler_mat_valid;
    logic        sampler_vec_valid;
    logic        sampler_out_ready;
    logic        sampler_mat_ready;
    logic        sampler_vec_ready;
    logic [47:0] sampler_out_data;
    logic [47:0] sampler_mat_data;
    logic [2:0]  sampler_out_count;
    logic        sampler_out_last;
    logic [3:0]  sampler_out_poly_index;
    logic        sampler_cmd_done;

    mlkem_hash_sampler #(.ENABLE_BYTE_STREAM(0)) hash_sampler_inst (
        .clk            (clk),
        .rst_n          (rst_n && enc_sub_rst_n_q),
        .cmd_valid      (dec_compute ? dec_s_cmd : enc_active ? enc_s_cmd_valid : sampler_cmd_valid),
        .cmd_ready      (sampler_cmd_ready),
        .cmd_mode       (dec_compute ? dec_s_mode : enc_active ? enc_s_mode : sampler_cmd_mode),
        .cmd_k          (enc_active ? enc_s_k : sampler_cmd_k),
        .cmd_seed       (enc_active ? enc_s_seed : sampler_cmd_seed),
        .cmd_seed_hi    (enc_h_q),
        .cmd_transpose  (enc_active ? 1'b1 : sampler_cmd_transpose),
        .cmd_eta3       (enc_active ? enc_s_eta3 : sampler_cmd_eta3),
        .cmd_nonce      (enc_active ? enc_s_nonce : sampler_cmd_nonce),
        .in_valid       (1'b0),
        .in_ready       (sampler_in_ready),
        .in_data        (8'd0),
        .in_last        (1'b0),
        .in_keep        (1'b0),
        .in_lane_mode   (sampler_in_lane_mode),
        .in_lane_valid  (dec_compute ? dec_lane_valid : enc_active ? enc_lane_valid : sampler_in_lane_valid),
        .in_lane_ready  (sampler_in_lane_ready),
        .in_lane        (dec_compute ? dec_lane : enc_active ? ek_in_data : sampler_in_lane),
        .in_last_block  (dec_compute ? dec_lane_last : enc_active ? enc_lane_last_block : sampler_in_last_block),
        .in_rem_lanes   (dec_compute ? dec_rem_lanes : sampler_in_rem_lanes),
        .digest_valid   (sampler_digest_valid),
        .digest_out     (sampler_digest_out),
        .digest_out_sigma (sampler_digest_out_sigma),
        .out_valid      (sampler_out_valid),
        .mat_out_valid  (sampler_mat_valid),
        .vec_out_valid  (sampler_vec_valid),
        .out_ready      (1'b1),
        .mat_out_ready  (sampler_mat_ready),
        .vec_out_ready  (sampler_vec_ready),
        .out_data       (sampler_out_data),
        .mat_out_data   (sampler_mat_data),
        .out_count      (sampler_out_count),
        .out_last       (sampler_out_last),
        .out_poly_index (sampler_out_poly_index),
        .cmd_done       (sampler_cmd_done)
    );

    // B. mlkem_ntt_intt Wires & Instantiation
    // Forward and inverse Number Theoretic Transform core over GF(q=3329)
    logic        ntt_cmd_valid;
    logic        ntt_cmd_ready;
    logic        ntt_cmd_mode;
    logic [2:0]  ntt_cmd_k;
    logic [4:0]  ntt_cmd_poly_count;

    logic        ntt_in_valid;
    logic        ntt_in_ready;
    logic [23:0] ntt_in_data;
    logic [1:0]  ntt_in_count;
    logic        ntt_in_last;
    logic [3:0]  ntt_in_poly_index;

    logic        ntt_out_valid;
    logic        ntt_out_ready;
    logic [23:0] ntt_out_data;
    logic [1:0]  ntt_out_count;
    logic        ntt_out_last;
    logic [3:0]  ntt_out_poly_index;
    logic        ntt_cmd_done;
    logic        ntt_cmd_error;

    // Address generation for NTT feed word streaming
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feed_word_addr_q <= 9'd0;
        end else if (dec_compute) begin
            if (dec_n_cmd && ntt_cmd_ready)
                feed_word_addr_q <= 9'd0;
            else if (dec_n_valid && ntt_in_ready && (dec_n_inverse || dec_feed_pair_q[0]))
                feed_word_addr_q <= feed_word_addr_q + 9'd1;
        end else if (enc_active) begin
            if (enc_n_cmd_valid && ntt_cmd_ready)
                feed_word_addr_q <= 9'd0;
            else if (enc_n_valid && ntt_in_ready && (enc_inverse || enc_feed_pair_q[0]))
                feed_word_addr_q <= feed_word_addr_q + 9'd1;
        end else begin
            feed_word_addr_q <= 9'd0;
        end
    end

    // NTT Input Multiplexing: decapsulation vs encapsulation vs keygen paths
    logic [23:0] ntt_in_data_mux;
    always_comb begin
        if (dec_compute) begin
            ntt_in_data_mux = dec_n_inverse ? enc_product_word[23:0] :
                              (dec_feed_pair_q[0] ? enc_product_word[47:24] : enc_product_word[23:0]);
        end else if (enc_active) begin
            ntt_in_data_mux = enc_inverse ? enc_product_word[23:0] :
                              (enc_feed_pair_q[0] ? ram_s_query_rdata[47:24] : ram_s_query_rdata[23:0]);
        end else begin
            ntt_in_data_mux = ntt_in_data;
        end
    end

    mlkem_ntt_intt ntt_inst (
        .clk            (clk),
        .rst_n          (rst_n && enc_sub_rst_n_q),
        .cmd_valid      (dec_compute ? dec_n_cmd : enc_active ? enc_n_cmd_valid : ntt_cmd_valid),
        .cmd_ready      (ntt_cmd_ready),
        .cmd_mode       (dec_compute ? dec_n_inverse : enc_active ? enc_inverse : ntt_cmd_mode),
        .cmd_k          (k_q),
        .cmd_poly_count (dec_compute ? dec_n_polys : enc_active ? enc_n_polys : ntt_cmd_poly_count),
        .in_valid       (dec_compute ? dec_n_valid : enc_active ? enc_n_valid : ntt_in_valid),
        .in_ready       (ntt_in_ready),
        .in_data        (ntt_in_data_mux),
        .in_wide        (dec_compute ? dec_n_inverse : enc_active && enc_inverse),
        .in_data_hi     (enc_product_word[47:24]),
        .in_count       (enc_active ? 2'd2 : ntt_in_count),
        .in_last        (dec_compute ? dec_n_last : enc_active ? enc_n_last : ntt_in_last),
        .in_poly_index  (dec_compute ? dec_n_poly : enc_active ? enc_n_poly : ntt_in_poly_index),
        .out_valid      (ntt_out_valid),
        .out_ready      (ntt_out_ready),
        .out_data       (ntt_out_data),
        .out_count      (ntt_out_count),
        .out_last       (ntt_out_last),
        .out_poly_index (ntt_out_poly_index),
        .cmd_done       (ntt_cmd_done),
        .cmd_error      (ntt_cmd_error)
    );

    assign ntt_out_ready = 1'b1;

    // C. mlkem_mul_stream Wires & Instantiation
    // 8-DSP streaming pointwise Montgomery multiplier (4 parallel lanes x 2 DSPs per lane)
    logic        mul_rst;
    logic        mul_stream_rst_q;
    logic        mul_s_valid;
    logic        mul_s_ready;
    logic        mul_s_start;
    logic        mul_s_accumulate;
    logic [1:0]  mul_s_mode;
    logic [2:0]  mul_s_k;
    logic [5:0]  mul_s_base_index;
    logic signed [12:0] mul_s_a0, mul_s_a1, mul_s_b0, mul_s_b1;
    logic signed [12:0] mul_s_a2, mul_s_a3, mul_s_b2, mul_s_b3;
    logic        mul_m_valid;
    logic        mul_m_ready;
    logic signed [11:0] mul_m_c0, mul_m_c1, mul_m_c2, mul_m_c3;
    logic [5:0]  mul_m_index;
    logic [1:0]  mul_m_row;
    logic        mul_m_last;

    mlkem_mul_stream mul_stream_inst (
        .clk          (clk),
        .rst          (mul_stream_rst_q),
        .s_valid      (dec_compute ? dec_mul_valid : enc_active ? enc_mul_valid : mul_s_valid),
        .s_ready      (mul_s_ready),
        .s_start      (dec_compute ? dec_mul_start : enc_active ? enc_mul_start_q : mul_s_start),
        .s_accumulate (mul_s_accumulate),
        .s_mode       (mul_s_mode),
        .s_k          (mul_s_k),
        .s_base_index (mul_s_base_index),
        .s_a0         (dec_compute ? $signed({1'b0,dec_mul_a[11:0]}) : mul_s_a0),
        .s_a1         (dec_compute ? $signed({1'b0,dec_mul_a[23:12]}) : mul_s_a1),
        .s_b0         (dec_compute ? $signed({1'b0,dec_mul_b[11:0]}) : enc_is_v_q ? $signed({1'b0,enc_pk_mul_word[11:0]}) : mul_s_b0),
        .s_b1         (dec_compute ? $signed({1'b0,dec_mul_b[23:12]}) : enc_is_v_q ? $signed({1'b0,enc_pk_mul_word[23:12]}) : mul_s_b1),
        .s_a2         (dec_compute ? $signed({1'b0,dec_mul_a[35:24]}) : mul_s_a2),
        .s_a3         (dec_compute ? $signed({1'b0,dec_mul_a[47:36]}) : mul_s_a3),
        .s_b2         (dec_compute ? $signed({1'b0,dec_mul_b[35:24]}) : enc_is_v_q ? $signed({1'b0,enc_pk_mul_word[35:24]}) : mul_s_b2),
        .s_b3         (dec_compute ? $signed({1'b0,dec_mul_b[47:36]}) : enc_is_v_q ? $signed({1'b0,enc_pk_mul_word[47:36]}) : mul_s_b3),
        .m_valid      (mul_m_valid),
        .m_ready      (mul_m_ready),
        .m_c0         (mul_m_c0),
        .m_c1         (mul_m_c1),
        .m_c2         (mul_m_c2),
        .m_c3         (mul_m_c3),
        .m_index      (mul_m_index),
        .m_row        (mul_m_row),
        .m_last       (mul_m_last)
    );

    // =========================================================================
    // 4. Sampler to NTT Unpacker & Vector e Decoupled Feeder
    // =========================================================================
    wire start_pulse = (start && ready);
    wire clr_state   = (fsm_q == ST_IDLE) || start_pulse;

    // 2-Entry Registered FIFO for Sampler -> NTT unpacker
    // Unpacks 4 coefficients per 48-bit sampler word into 2 coefficients per 24-bit NTT beat
    logic [47:0] s_fifo_data   [0:1];
    logic        s_fifo_last   [0:1];
    logic [3:0]  s_fifo_poly   [0:1];
    logic [1:0]  s_fifo_cnt_q;
    logic        s_fifo_wr_ptr_q;
    logic        s_fifo_rd_ptr_q;
    logic        s_fifo_phase_q; // 0: lower 24 bits (coeffs 0,1), 1: upper 24 bits (coeffs 2,3)
    logic        s_sampler_ready_q;
    logic        s_sampler_done_q;

    wire s_push_beat = (fsm_q == ST_SAMPLE_S) && sampler_vec_valid && s_sampler_ready_q;
    wire s_pop_beat  = (fsm_q == ST_SAMPLE_S) && (s_fifo_cnt_q > 2'd0) && ntt_in_ready && s_fifo_phase_q;

    logic [1:0] next_s_fifo_cnt;
    always_comb begin
        case ({s_push_beat, s_pop_beat})
            2'b10: next_s_fifo_cnt = s_fifo_cnt_q + 1'b1;
            2'b01: next_s_fifo_cnt = s_fifo_cnt_q - 1'b1;
            default: next_s_fifo_cnt = s_fifo_cnt_q;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_fifo_cnt_q      <= 2'd0;
            s_fifo_wr_ptr_q   <= 1'b0;
            s_fifo_rd_ptr_q   <= 1'b0;
            s_fifo_phase_q    <= 1'b0;
            s_sampler_ready_q <= 1'b0;
            for (int i = 0; i < 2; i++) begin
                s_fifo_data[i] <= '0;
                s_fifo_last[i] <= 1'b0;
                s_fifo_poly[i] <= '0;
            end
        end else if (clr_state) begin
            s_fifo_cnt_q      <= 2'd0;
            s_fifo_wr_ptr_q   <= 1'b0;
            s_fifo_rd_ptr_q   <= 1'b0;
            s_fifo_phase_q    <= 1'b0;
            s_sampler_ready_q <= 1'b0;
        end else if (fsm_q == ST_START_NTT) begin
            s_fifo_cnt_q      <= 2'd0;
            s_fifo_wr_ptr_q   <= 1'b0;
            s_fifo_rd_ptr_q   <= 1'b0;
            s_fifo_phase_q    <= 1'b0;
            s_sampler_ready_q <= 1'b1; // Empty buffer ready to receive
        end else if (fsm_q == ST_SAMPLE_S) begin
            s_fifo_cnt_q      <= next_s_fifo_cnt;
            s_sampler_ready_q <= (next_s_fifo_cnt < 2'd2);

            if (s_push_beat) begin
                s_fifo_data[s_fifo_wr_ptr_q] <= sampler_out_data;
                s_fifo_last[s_fifo_wr_ptr_q] <= sampler_out_last;
                s_fifo_poly[s_fifo_wr_ptr_q] <= sampler_out_poly_index;
                s_fifo_wr_ptr_q              <= ~s_fifo_wr_ptr_q;
            end

            if ((s_fifo_cnt_q > 2'd0) && ntt_in_ready) begin
                if (!s_fifo_phase_q) begin
                    s_fifo_phase_q <= 1'b1;
                end else begin
                    s_fifo_phase_q  <= 1'b0;
                    s_fifo_rd_ptr_q <= ~s_fifo_rd_ptr_q;
                end
            end
        end else begin
            s_sampler_ready_q <= 1'b0;
        end
    end

    // Vector e direct sampling into ram_e (runs at full 4-coeff/cycle burst speed)
    logic [5:0] e_sample_beat_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_sample_beat_q <= 6'd0;
        end else if (clr_state) begin
            e_sample_beat_q <= 6'd0;
        end else if (fsm_q == ST_SAMPLE_E && sampler_vec_valid) begin
            e_sample_beat_q <= sampler_out_last ? 6'd0 : e_sample_beat_q + 1'b1;
        end
    end

    // Vector e feeder from ram_e into ntt_inst (runs concurrently with Matrix A)
    // Dedicated, independent read ports on ram_e eliminate cross-module multiplexing
    logic [2:0] e_feed_poly_q;
    logic [5:0] e_feed_beat_q;
    logic       e_feed_phase_q;
    logic       e_feed_active_q;

    wire [47:0] dec_ram_e_rdata   = ram_e[dec_mul_word_q[7:0]];
    wire [47:0] keygen_ram_e_feed = ram_e[{e_feed_poly_q[1:0], e_feed_beat_q}];
    wire [7:0]  ram_e_accum_raddr = enc_active ? {ntt_out_poly_index[1:0], enc_result_pair_q[6:1]} : {accum_row_q[1:0], accum_beat_q};
    wire [47:0] ram_e_accum_rdata = ram_e[ram_e_accum_raddr];

    wire [5:0] next_e_feed_beat = (e_feed_beat_q == 6'd63) ? 6'd0 : (e_feed_beat_q + 1'b1);
    wire [1:0] next_e_feed_poly = (e_feed_beat_q == 6'd63) ? (e_feed_poly_q[1:0] + 1'b1) : e_feed_poly_q[1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            e_feed_active_q <= 1'b0;
            e_feed_poly_q   <= 3'd0;
            e_feed_beat_q   <= 6'd0;
            e_feed_phase_q  <= 1'b0;
        end else if (clr_state) begin
            e_feed_active_q <= 1'b0;
            e_feed_poly_q   <= 3'd0;
            e_feed_beat_q   <= 6'd0;
            e_feed_phase_q  <= 1'b0;
        end else begin
            if (fsm_q == ST_SAMPLE_E && sampler_cmd_done) begin
                e_feed_active_q <= 1'b1;
                e_feed_poly_q   <= 3'd0;
                e_feed_beat_q   <= 6'd0;
                e_feed_phase_q  <= 1'b0;
            end else if (e_feed_active_q && ntt_in_ready) begin
                if (!e_feed_phase_q) begin
                    e_feed_phase_q <= 1'b1;
                end else begin
                    e_feed_phase_q <= 1'b0;
                    if (e_feed_beat_q == 6'd63) begin
                        e_feed_beat_q <= 6'd0;
                        if (e_feed_poly_q == k_q - 1'b1) begin
                            e_feed_active_q <= 1'b0;
                        end else begin
                            e_feed_poly_q <= e_feed_poly_q + 1'b1;
                        end
                    end else begin
                        e_feed_beat_q <= e_feed_beat_q + 1'b1;
                    end
                end
            end
        end
    end

    // Dedicated sampler ready multiplexing - factored mul_s_ready to shorten critical path
    wire cur_mat_op_ready    = enc_active ? enc_mat_req_ready : (fsm_sample_a_q && col_s_ready_q);
    assign sampler_vec_ready = (fsm_q == ST_SAMPLE_S) ? s_sampler_ready_q : 1'b1;
    assign sampler_mat_ready = mul_s_ready && cur_mat_op_ready;
    assign sampler_out_ready = enc_active ? enc_out_ready
                                          : (fsm_sample_a_q ? sampler_mat_ready : sampler_vec_ready);

    // NTT input multiplexing: select between vector s sampling and vector e feeding
    always_comb begin
        if (fsm_q == ST_SAMPLE_S) begin
            ntt_in_valid      = (s_fifo_cnt_q > 2'd0);
            ntt_in_data       = (!s_fifo_phase_q) ? s_fifo_data[s_fifo_rd_ptr_q][23:0] : s_fifo_data[s_fifo_rd_ptr_q][47:24];
            ntt_in_last       = s_fifo_phase_q && s_fifo_last[s_fifo_rd_ptr_q];
            ntt_in_count      = 2'd2;
            ntt_in_poly_index = s_fifo_poly[s_fifo_rd_ptr_q];
        end else if (e_feed_active_q) begin
            ntt_in_valid      = 1'b1;
            ntt_in_data       = (!e_feed_phase_q) ? keygen_ram_e_feed[23:0] : keygen_ram_e_feed[47:24];
            ntt_in_last       = e_feed_phase_q && (e_feed_beat_q == 6'd63);
            ntt_in_count      = 2'd2;
            ntt_in_poly_index = e_feed_poly_q + k_q;
        end else begin
            ntt_in_valid      = 1'b0;
            ntt_in_data       = '0;
            ntt_in_last       = 1'b0;
            ntt_in_count      = 2'd0;
            ntt_in_poly_index = '0;
        end
    end

    // =========================================================================
    // 5. NTT Output Collector & ram_e Write Arbitration
    // =========================================================================
    logic [23:0] ntt_lo_q;
    logic        ntt_pack_phase_q;
    logic [5:0]  ntt_word_idx_q;

    logic        ram_e_we_q;
    logic [7:0]  ram_e_waddr_q;
    logic [47:0] ram_e_wdata_q;

    // Collect 24-bit half-words from NTT and pack into 48-bit words for ram_e
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_e_we_q    <= 1'b0;
            ram_e_waddr_q <= 8'd0;
            ram_e_wdata_q <= 48'd0;
        end else if (clr_state) begin
            ram_e_we_q    <= 1'b0;
            ram_e_waddr_q <= 8'd0;
            ram_e_wdata_q <= 48'd0;
        end else begin
            ram_e_we_q    <= !enc_active && ((fsm_q == ST_SAMPLE_E && sampler_vec_valid) ||
                             (ntt_out_valid && ntt_out_ready && ntt_pack_phase_q && (ntt_out_poly_index >= k_q)));
            ram_e_waddr_q <= (fsm_q == ST_SAMPLE_E) ?
                             {sampler_out_poly_index[1:0], e_sample_beat_q} :
                             {(ntt_out_poly_index[1:0] - k_q[1:0]), ntt_word_idx_q};
            ram_e_wdata_q <= (fsm_q == ST_SAMPLE_E) ?
                             sampler_out_data :
                             {ntt_out_data, ntt_lo_q};
        end
    end

    // ram_e Write Port Arbitration: Decap secret key vs Encap e1 vs KeyGen e
    always_ff @(posedge clk) begin
        if (dec_sk_write) begin
            ram_e[dec_sk_addr] <= dec_sk_data;
        end else if (enc_e1_write) begin
            ram_e[{sampler_out_poly_index[1:0],enc_sample_beat_q}] <= sampler_out_data;
        end else if (ram_e_we_q) begin
            ram_e[ram_e_waddr_q] <= ram_e_wdata_q;
        end
    end

    // ram_s Write Port Arbitration: Banked write into ram_s_b0..b3
    wire        dec_ram_s_we    = dec_compute && !dec_n_inverse && ntt_out_valid && ntt_pack_phase_q;
    wire        keygen_ram_s_we = !dec_compute && !(enc_active && enc_inverse) && ntt_out_valid && ntt_pack_phase_q && (ntt_out_poly_index < k_q);
    wire        ram_s_we        = dec_compute ? dec_ram_s_we : keygen_ram_s_we;
    wire [1:0]  ram_s_wbank     = enc_r_write ? sampler_out_poly_index[1:0] : ntt_out_poly_index[1:0];
    wire [5:0]  ram_s_waddr_idx = enc_r_write ? enc_sample_beat_q : ntt_word_idx_q;
    wire [47:0] ram_s_wdata_val = enc_r_write ? sampler_out_data : {ntt_out_data, ntt_lo_q};
    wire        ram_s_write_en  = enc_r_write || ram_s_we;

    always_ff @(posedge clk) begin
        if (ram_s_write_en && ram_s_wbank == 2'd0) ram_s_b0[ram_s_waddr_idx] <= ram_s_wdata_val;
        if (ram_s_write_en && ram_s_wbank == 2'd1) ram_s_b1[ram_s_waddr_idx] <= ram_s_wdata_val;
        if (ram_s_write_en && ram_s_wbank == 2'd2) ram_s_b2[ram_s_waddr_idx] <= ram_s_wdata_val;
        if (ram_s_write_en && ram_s_wbank == 2'd3) ram_s_b3[ram_s_waddr_idx] <= ram_s_wdata_val;
    end

    // NTT output packing phase and polynomial readiness tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ntt_lo_q         <= '0;
            ntt_pack_phase_q <= 1'b0;
            ntt_word_idx_q   <= 6'd0;
            s_ready_mask_q   <= 4'd0;
            e_ready_mask_q   <= 4'd0;
        end else if (clr_state || dec_kick) begin
            ntt_lo_q         <= '0;
            ntt_pack_phase_q <= 1'b0;
            ntt_word_idx_q   <= 6'd0;
            s_ready_mask_q   <= 4'd0;
            e_ready_mask_q   <= 4'd0;
        end else if (ntt_out_valid && ntt_out_ready) begin
            if (!ntt_pack_phase_q) begin
                ntt_lo_q         <= ntt_out_data;
                ntt_pack_phase_q <= 1'b1;
            end else begin
                ntt_pack_phase_q <= 1'b0;
                ntt_word_idx_q   <= ntt_out_last ? 6'd0 : ntt_word_idx_q + 1'b1;

                if (ntt_out_poly_index < k_q && !(enc_active && enc_inverse)) begin
                    if (ntt_out_last) begin
                        $display("      [k=%0d cycle=%0d] NTT finished poly s[%0d]", k_q, cycle_cnt_q, ntt_out_poly_index);
                        s_ready_mask_q[ntt_out_poly_index[1:0]] <= 1'b1;
                    end
                end else if (!enc_active) begin
                    if (ntt_out_last) begin
                        $display("      [k=%0d cycle=%0d] NTT finished poly e[%0d]", k_q, cycle_cnt_q, ntt_out_poly_index - k_q);
                        e_ready_mask_q[(ntt_out_poly_index[1:0] - k_q[1:0])] <= 1'b1;
                    end
                end
            end
        end
    end

    // Dedicated registered status for active column polynomial s readiness
    // Breaks combinational backpropagation into hash_sampler and keccak_f1600 clock enable
    wire ntt_s_poly_done = ntt_out_valid && ntt_out_ready && ntt_pack_phase_q && (ntt_out_poly_index < k_q) && ntt_out_last;
    wire [3:0] s_mask_updated = ntt_s_poly_done ? (s_ready_mask_q | (4'b1 << ntt_out_poly_index[1:0])) : s_ready_mask_q;

    wire [1:0] next_col_calc = (mat_col_q == k_q - 1'b1) ? 2'd0 : (mat_col_q[1:0] + 1'b1);
    wire mat_col_fire = fsm_sample_a_q && sampler_mat_valid && mul_s_ready && col_s_ready_q && (mat_beat_q == 6'd63);
    wire [1:0] active_col_next = mat_col_fire ? next_col_calc : mat_col_q[1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_s_ready_q <= 1'b0;
        end else if (clr_state) begin
            col_s_ready_q <= 1'b0;
        end else begin
            col_s_ready_q <= s_mask_updated[active_col_next];
        end
    end

    // =========================================================================
    // 6. Matrix-Vector Multiplier Feed & Read Control
    // =========================================================================
    // Dedicated read ports for ram_s: compute port, enc query port, and dk readout port
    wire [7:0]  ram_s_compute_raddr = dec_compute ? dec_mul_word_q[7:0] :
                                      enc_active ? {enc_mul_col_q[1:0], enc_mul_beat_q} :
                                      {mat_col_q[1:0], mat_beat_q};

    logic mul_rst_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_rst_q <= 1'b1;
        end else if (clr_state) begin
            mul_rst_q <= 1'b1;
        end else begin
            mul_rst_q <= !fsm_sample_a_q;
        end
    end
    assign mul_rst          = mul_rst_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mul_stream_rst_q <= 1'b1;
        end else if (start_pulse || enc_abort) begin
            mul_stream_rst_q <= 1'b1;
        end else if (dec_compute) begin
            mul_stream_rst_q <= 1'b0;
        end else if (enc_active) begin
            mul_stream_rst_q <= enc_mul_rst;
        end else begin
            mul_stream_rst_q <= mul_rst_q;
        end
    end

    // Registered matrix polynomial start indicator to eliminate combinational comparator path
    logic mat_start_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mat_start_q <= 1'b1;
        end else if (clr_state) begin
            mat_start_q <= 1'b1;
        end else if (fsm_sample_a_q) begin
            if (sampler_mat_valid && sampler_mat_ready) begin
                mat_start_q <= (mat_beat_q == 6'd63);
            end
        end else begin
            mat_start_q <= 1'b1;
        end
    end

    assign mul_s_valid      = fsm_sample_a_q && sampler_mat_valid && col_s_ready_q;
    assign mul_s_start      = mat_start_q;
    assign mul_s_mode       = 2'd1; // Polynomial pointwise PWM mode
    assign mul_s_k          = k_q;
    assign mul_s_base_index = 6'd0;
    assign mul_s_accumulate = 1'b0; // ram_t performs row accumulation externally

    // Feed multiplier coefficients: s_word (s) and sampler_mat_data (matrix A)
    assign mul_s_a0 = $signed({1'b0, s_word_read[11:0]});
    assign mul_s_a1 = $signed({1'b0, s_word_read[23:12]});
    assign mul_s_b0 = $signed({1'b0, sampler_mat_data[11:0]});
    assign mul_s_b1 = $signed({1'b0, sampler_mat_data[23:12]});
    assign mul_s_a2 = $signed({1'b0, s_word_read[35:24]});
    assign mul_s_a3 = $signed({1'b0, s_word_read[47:36]});
    assign mul_s_b2 = $signed({1'b0, sampler_mat_data[35:24]});
    assign mul_s_b3 = $signed({1'b0, sampler_mat_data[47:36]});

    // Tracking matrix sampling coordinates (row, col, beat)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mat_beat_q <= 6'd0;
            mat_row_q  <= 3'd0;
            mat_col_q  <= 3'd0;
        end else if (clr_state) begin
            mat_beat_q <= 6'd0;
            mat_row_q  <= 3'd0;
            mat_col_q  <= 3'd0;
        end else if (fsm_sample_a_q) begin
            if (sampler_mat_valid && mul_s_ready && col_s_ready_q) begin
                if (mat_beat_q == 6'd63) begin
                    mat_beat_q <= 6'd0;
                    if (mat_col_q == k_q - 1'b1) begin
                        mat_col_q <= 3'd0;
                        mat_row_q <= mat_row_q + 1'b1;
                    end else begin
                        mat_col_q <= mat_col_q + 1'b1;
                    end
                end else begin
                    mat_beat_q <= mat_beat_q + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 7. Multiplier Output Accumulator and Public Key Writer (Pipelined)
    // =========================================================================
    // Canonical reduction function: converts negative signed 12-bit modular values to [0, 3328]
    function automatic logic [11:0] canon12(input logic signed [11:0] v);
        canon12 = v[11] ? v + 12'd3329 : v;
    endfunction

    // Modular addition over Z_q: computes (a + b) mod 3329
    function automatic logic [11:0] add_q(input logic [11:0] a, input logic [11:0] b);
        logic [12:0] sum;
        logic [12:0] sum_sub;
        sum = {1'b0, a} + {1'b0, b};
        sum_sub = sum - 13'd3329;
        add_q = sum_sub[12] ? sum[11:0] : sum_sub[11:0];
    endfunction

    // Multiplier output ready: stall if waiting for error vector e to finish NTT
    assign mul_m_ready = enc_active ? 1'b1 : (accum_row_lt_k_q && (!is_last_col_q || e_ready_mask_q[accum_row_q[1:0]]));

    // Multiplier output coordinate tracking
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_row_q         <= 3'd0;
            accum_col_q         <= 3'd0;
            accum_beat_q        <= 6'd0;
            is_last_col_q       <= 1'b0;
            accum_row_lt_k_q    <= 1'b1;
            accum_row_is_last_q <= 1'b0;
        end else if (clr_state || dec_kick) begin
            accum_row_q         <= 3'd0;
            accum_col_q         <= 3'd0;
            accum_beat_q        <= 6'd0;
            is_last_col_q       <= 1'b0;
            accum_row_lt_k_q    <= 1'b1;
            accum_row_is_last_q <= 1'b0;
        end else if (mul_m_valid && mul_m_ready) begin
            if (accum_beat_q == 6'd63) begin
                accum_beat_q <= 6'd0;
                if (is_last_col_q) begin
                    accum_col_q         <= 3'd0;
                    is_last_col_q       <= 1'b0;
                    accum_row_q         <= accum_row_q + 1'b1;
                    accum_row_lt_k_q    <= (accum_row_q + 1'b1 < k_q);
                    accum_row_is_last_q <= (accum_row_q + 1'b1 == k_q - 1'b1);
                end else begin
                    accum_col_q         <= accum_col_q + 1'b1;
                    is_last_col_q       <= (accum_col_q + 1'b1 == k_q - 1'b1);
                end
            end else begin
                accum_beat_q <= accum_beat_q + 1'b1;
            end
        end
    end

    // --- Pipeline Stage 1: Capture multiplier outputs and read operands ---
    logic        p1_valid;
    logic [5:0]  p1_beat;
    logic [2:0]  p1_row;
    logic [2:0]  p1_col;
    logic        p1_is_last_col;
    logic        p1_is_last_mat_beat;
    logic [11:0] p1_prod0, p1_prod1, p1_prod2, p1_prod3;
    logic [47:0] p1_t_curr;
    logic [47:0] p1_e_curr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
        end else if (clr_state) begin
            p1_valid <= 1'b0;
        end else begin
            p1_valid <= mul_m_valid && mul_m_ready;
        end
    end

    // Datapath operands captured without asynchronous reset (ensures pure LUTRAM inference)
    always_ff @(posedge clk) begin
        if (mul_m_valid && mul_m_ready) begin
            p1_beat             <= accum_beat_q;
            p1_row              <= accum_row_q;
            p1_col              <= accum_col_q;
            p1_is_last_col      <= is_last_col_q;
            p1_is_last_mat_beat <= accum_row_is_last_q && is_last_col_q && (accum_beat_q == 6'd63);
            p1_prod0            <= canon12(mul_m_c0);
            p1_prod1            <= canon12(mul_m_c1);
            p1_prod2            <= canon12(mul_m_c2);
            p1_prod3            <= canon12(mul_m_c3);
            p1_t_curr           <= (accum_col_q == 3'd0) ? 48'd0 : ram_t[accum_beat_q];
            p1_e_curr           <= enc_active ? 48'd0 : ram_e_accum_rdata;
        end else begin
            p1_is_last_mat_beat <= 1'b0;
        end
    end

    // --- Pipeline Stage 2: First modular addition sum1 = t_curr + prod ---
    logic        p2_valid;
    logic [5:0]  p2_beat;
    logic [2:0]  p2_row;
    logic        p2_is_last_col;
    logic        p2_is_last_mat_beat;
    logic [47:0] p2_sum1;
    logic [47:0] p2_e_curr;

    wire [11:0] s1_c0 = add_q(p1_t_curr[11:0],  p1_prod0);
    wire [11:0] s1_c1 = add_q(p1_t_curr[23:12], p1_prod1);
    wire [11:0] s1_c2 = add_q(p1_t_curr[35:24], p1_prod2);
    wire [11:0] s1_c3 = add_q(p1_t_curr[47:36], p1_prod3);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2_valid            <= 1'b0;
            p2_beat             <= 6'd0;
            p2_row              <= 3'd0;
            p2_is_last_col      <= 1'b0;
            p2_is_last_mat_beat <= 1'b0;
        end else if (clr_state) begin
            p2_valid            <= 1'b0;
            p2_beat             <= 6'd0;
            p2_row              <= 3'd0;
            p2_is_last_col      <= 1'b0;
            p2_is_last_mat_beat <= 1'b0;
        end else begin
            p2_valid            <= p1_valid;
            p2_beat             <= p1_beat;
            p2_row              <= p1_row;
            p2_is_last_col      <= p1_is_last_col;
            p2_is_last_mat_beat <= p1_valid && p1_is_last_mat_beat;
        end
    end

    always_ff @(posedge clk) begin
        p2_sum1   <= {s1_c3, s1_c2, s1_c1, s1_c0};
        p2_e_curr <= p1_e_curr;
    end

    // Write intermediate accumulator results into ram_t for non-final columns
    always_ff @(posedge clk) begin
        if (p2_valid && !p2_is_last_col) begin
            ram_t[p2_beat] <= p2_sum1;
        end
    end

    // --- Pipeline Stage 3: Second modular addition final = sum1 + e_curr (for last column) ---
    logic        p3_valid;
    logic [5:0]  p3_beat;
    logic [2:0]  p3_row;
    logic        p3_is_last_col;
    logic        p3_is_last_mat_beat;
    logic [47:0] p3_final;

    wire [11:0] fn_c0 = add_q(p2_sum1[11:0],  p2_e_curr[11:0]);
    wire [11:0] fn_c1 = add_q(p2_sum1[23:12], p2_e_curr[23:12]);
    wire [11:0] fn_c2 = add_q(p2_sum1[35:24], p2_e_curr[35:24]);
    wire [11:0] fn_c3 = add_q(p2_sum1[47:36], p2_e_curr[47:36]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p3_valid            <= 1'b0;
            p3_beat             <= 6'd0;
            p3_row              <= 3'd0;
            p3_is_last_col      <= 1'b0;
            p3_is_last_mat_beat <= 1'b0;
        end else if (clr_state) begin
            p3_valid            <= 1'b0;
            p3_beat             <= 6'd0;
            p3_row              <= 3'd0;
            p3_is_last_col      <= 1'b0;
            p3_is_last_mat_beat <= 1'b0;
        end else begin
            p3_valid            <= p2_valid;
            p3_beat             <= p2_beat;
            p3_row              <= p2_row;
            p3_is_last_col      <= p2_is_last_col;
            p3_is_last_mat_beat <= p2_valid && p2_is_last_mat_beat;
        end
    end

    always_ff @(posedge clk) begin
        p3_final <= {fn_c3, fn_c2, fn_c1, fn_c0};
    end

    // Write final public key polynomial into ram_pk_b0..b3
    wire [7:0] p3_pk_waddr   = {p3_row[1:0], p3_beat};
    wire [1:0] p3_bank_sel   = p3_pk_waddr[1:0];
    wire [5:0] p3_bank_waddr = p3_pk_waddr[7:2];

    always_ff @(posedge clk) begin
        if (enc_pk_write) begin
            case (enc_pk_word_q[1:0])
                0: ram_pk_b0[enc_pk_word_q[7:2]] <= enc_pk_word;
                1: ram_pk_b1[enc_pk_word_q[7:2]] <= enc_pk_word;
                2: ram_pk_b2[enc_pk_word_q[7:2]] <= enc_pk_word;
                3: ram_pk_b3[enc_pk_word_q[7:2]] <= enc_pk_word;
            endcase
        end else if (!enc_active) begin
            if (p3_valid && p3_is_last_col && p3_bank_sel == 2'd0) ram_pk_b0[p3_bank_waddr] <= p3_final;
            if (p3_valid && p3_is_last_col && p3_bank_sel == 2'd1) ram_pk_b1[p3_bank_waddr] <= p3_final;
            if (p3_valid && p3_is_last_col && p3_bank_sel == 2'd2) ram_pk_b2[p3_bank_waddr] <= p3_final;
            if (p3_valid && p3_is_last_col && p3_bank_sel == 2'd3) ram_pk_b3[p3_bank_waddr] <= p3_final;
        end
    end

    // --- Pipeline Stage 4: Commit notification for FSM ---
    logic p4_is_last_mat_beat;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p4_is_last_mat_beat <= 1'b0;
        end else if (clr_state) begin
            p4_is_last_mat_beat <= 1'b0;
        end else begin
            p4_is_last_mat_beat <= p3_valid && p3_is_last_mat_beat;
        end
    end

    wire all_mat_rows_done = p4_is_last_mat_beat;

    // =========================================================================
    // 8. 64-Bit Lane Generation for SHA3-256 (On-the-Fly Streamed)
    // =========================================================================
    logic [7:0] total_sha_lanes_q;
    logic [7:0] full_block_lanes_q;
    logic [4:0] sampler_in_rem_lanes_q;

    // Lane count parameters for SHA3-256 absorption of ek = ByteEncode12(t) || rho
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_sha_lanes_q      <= 8'd100;
            full_block_lanes_q     <= 8'd85;
            sampler_in_rem_lanes_q <= 5'd15;
        end else if (start_pulse) begin
            total_sha_lanes_q      <= (k == 3'd2) ? 8'd100 : (k == 3'd3) ? 8'd148 : 8'd196;
            full_block_lanes_q     <= (k == 3'd2) ? 8'd85  : (k == 3'd3) ? 8'd136 : 8'd187;
            sampler_in_rem_lanes_q <= (k == 3'd2) ? 5'd15  : (k == 3'd3) ? 5'd12  : 5'd9;
        end
    end

    wire [7:0] total_sha_lanes   = total_sha_lanes_q;
    wire [7:0] full_block_lanes  = full_block_lanes_q;
    assign sampler_in_rem_lanes  = sampler_in_rem_lanes_q;

    logic [7:0] sha_lane_cnt_q;
    (* max_fanout = 32 *) logic [5:0] sha_grp_q;
    logic [1:0] sha_rem_q;
    logic       sha_last_block_q;
    logic       sha_lane_valid_q;
    assign sampler_in_last_block = sha_last_block_q;
    assign sampler_in_lane_valid = sha_lane_valid_q;

    wire [1:0] rem_idx = sha_rem_q;

    // Dedicated read ports for distributed RAM:
    // Port A: internal pipeline computation / multiplier
    // Port B: NTT feeding during encap
    // Port C: host query readout (dk readout)
    wire [47:0] ram_s_comp_b0 = ram_s_b0[ram_s_compute_raddr[5:0]];
    wire [47:0] ram_s_comp_b1 = ram_s_b1[ram_s_compute_raddr[5:0]];
    wire [47:0] ram_s_comp_b2 = ram_s_b2[ram_s_compute_raddr[5:0]];
    wire [47:0] ram_s_comp_b3 = ram_s_b3[ram_s_compute_raddr[5:0]];
    assign s_word_read = (ram_s_compute_raddr[7:6] == 2'd0) ? ram_s_comp_b0 :
                         (ram_s_compute_raddr[7:6] == 2'd1) ? ram_s_comp_b1 :
                         (ram_s_compute_raddr[7:6] == 2'd2) ? ram_s_comp_b2 :
                                                              ram_s_comp_b3;

    wire [47:0] ram_s_query_b0 = ram_s_b0[feed_word_addr_q[5:0]];
    wire [47:0] ram_s_query_b1 = ram_s_b1[feed_word_addr_q[5:0]];
    wire [47:0] ram_s_query_b2 = ram_s_b2[feed_word_addr_q[5:0]];
    wire [47:0] ram_s_query_b3 = ram_s_b3[feed_word_addr_q[5:0]];
    assign ram_s_query_rdata = (feed_word_addr_q[7:6] == 2'd0) ? ram_s_query_b0 :
                               (feed_word_addr_q[7:6] == 2'd1) ? ram_s_query_b1 :
                               (feed_word_addr_q[7:6] == 2'd2) ? ram_s_query_b2 :
                                                                 ram_s_query_b3;

    wire [47:0] ram_s_dk_b0 = ram_s_b0[dk_s_word[5:0]];
    wire [47:0] ram_s_dk_b1 = ram_s_b1[dk_s_word[5:0]];
    wire [47:0] ram_s_dk_b2 = ram_s_b2[dk_s_word[5:0]];
    wire [47:0] ram_s_dk_b3 = ram_s_b3[dk_s_word[5:0]];
    assign ram_s_dk_rdata = (dk_s_word[7:6] == 2'd0) ? ram_s_dk_b0 :
                            (dk_s_word[7:6] == 2'd1) ? ram_s_dk_b1 :
                            (dk_s_word[7:6] == 2'd2) ? ram_s_dk_b2 :
                                                       ram_s_dk_b3;

    // Decoupled read ports for ram_pk_b0..b3 (natively maps to UltraScale RAM64M read ports)
    // KeyGen SHA hash read ports: driven solely by sha_grp_q
    assign sha_w0 = ram_pk_b0[sha_grp_q];
    assign sha_w1 = ram_pk_b1[sha_grp_q];
    assign sha_w2 = ram_pk_b2[sha_grp_q];
    assign sha_w3 = ram_pk_b3[sha_grp_q];

    // Dedicated Encap multiplier read ports: driven solely by enc_pk_group_q
    wire [47:0] enc_w0 = ram_pk_b0[enc_pk_group_q];
    wire [47:0] enc_w1 = ram_pk_b1[enc_pk_group_q];
    wire [47:0] enc_w2 = ram_pk_b2[enc_pk_group_q];
    wire [47:0] enc_w3 = ram_pk_b3[enc_pk_group_q];

    // Host memory query read ports for ram_pk_b0..b3
    assign q_w0   = ram_pk_b0[ek_t_word[7:2]];
    assign q_w1   = ram_pk_b1[ek_t_word[7:2]];
    assign q_w2   = ram_pk_b2[ek_t_word[7:2]];
    assign q_w3   = ram_pk_b3[ek_t_word[7:2]];

    // Extract individual byte from 48-bit packed coefficient word (4 x 12-bit coeffs)
    function automatic logic [7:0] get_c_byte(input logic [47:0] w, input logic [2:0] sub);
        case (sub)
            3'd0: get_c_byte = w[7:0];
            3'd1: get_c_byte = {w[15:12], w[11:8]};
            3'd2: get_c_byte = w[23:16];
            3'd3: get_c_byte = w[31:24];
            3'd4: get_c_byte = {w[39:36], w[35:32]};
            default: get_c_byte = w[47:40];
        endcase
    endfunction

    logic [47:0] pk_word_for_mem;
    always_comb begin
        case (ek_t_word[1:0])
            2'd0: pk_word_for_mem = q_w0;
            2'd1: pk_word_for_mem = q_w1;
            2'd2: pk_word_for_mem = q_w2;
            default: pk_word_for_mem = q_w3;
        endcase
    end

    // Assemble 24 bytes from keygen compute read ports sha_w0..sha_w3
    wire [7:0] B [0:23];
    assign B[0]  = get_c_byte(sha_w0, 3'd0);
    assign B[1]  = get_c_byte(sha_w0, 3'd1);
    assign B[2]  = get_c_byte(sha_w0, 3'd2);
    assign B[3]  = get_c_byte(sha_w0, 3'd3);
    assign B[4]  = get_c_byte(sha_w0, 3'd4);
    assign B[5]  = get_c_byte(sha_w0, 3'd5);

    assign B[6]  = get_c_byte(sha_w1, 3'd0);
    assign B[7]  = get_c_byte(sha_w1, 3'd1);
    assign B[8]  = get_c_byte(sha_w1, 3'd2);
    assign B[9]  = get_c_byte(sha_w1, 3'd3);
    assign B[10] = get_c_byte(sha_w1, 3'd4);
    assign B[11] = get_c_byte(sha_w1, 3'd5);

    assign B[12] = get_c_byte(sha_w2, 3'd0);
    assign B[13] = get_c_byte(sha_w2, 3'd1);
    assign B[14] = get_c_byte(sha_w2, 3'd2);
    assign B[15] = get_c_byte(sha_w2, 3'd3);
    assign B[16] = get_c_byte(sha_w2, 3'd4);
    assign B[17] = get_c_byte(sha_w2, 3'd5);

    assign B[18] = get_c_byte(sha_w3, 3'd0);
    assign B[19] = get_c_byte(sha_w3, 3'd1);
    assign B[20] = get_c_byte(sha_w3, 3'd2);
    assign B[21] = get_c_byte(sha_w3, 3'd3);
    assign B[22] = get_c_byte(sha_w3, 3'd4);
    assign B[23] = get_c_byte(sha_w3, 3'd5);

    wire [1:0] rho_lane_idx = sha_lane_cnt_q[1:0];

    // Stream 64-bit lanes into SHA engine: ByteEncode12(t) followed by rho
    always_comb begin
        if (sha_lane_cnt_q < t_lanes_total_q) begin
            case (rem_idx)
                2'd0: sampler_in_lane = {B[7],  B[6],  B[5],  B[4],  B[3],  B[2],  B[1],  B[0]};
                2'd1: sampler_in_lane = {B[15], B[14], B[13], B[12], B[11], B[10], B[9],  B[8]};
                default: sampler_in_lane = {B[23], B[22], B[21], B[20], B[19], B[18], B[17], B[16]};
            endcase
        end else begin
            sampler_in_lane = rho_q[rho_lane_idx*64 +: 64];
        end
    end

    // =========================================================================
    // 9. Master KeyGen FSM & Boundary Output Registers
    // =========================================================================
    logic ready_q;
    logic done_q;
    assign ready = ready_q;
    assign done  = done_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_q              <= ST_IDLE;
            ready_q            <= 1'b1;
            done_q             <= 1'b0;
            fsm_sample_a_q     <= 1'b0;
            mode_q             <= 2'd0;
            seed_d_q           <= '0;
            seed_z_q           <= '0;
            k_q                <= '0;
            t_lanes_total_q    <= 8'd0;
            k_invalid_q        <= 1'b0;
            rho_q              <= '0;
            sigma_q            <= '0;
            h_ek_q             <= '0;
            cycle_cnt_q        <= 32'd0;
            sha_lane_cnt_q     <= 8'd0;
            sha_grp_q          <= 6'd0;
            sha_rem_q          <= 2'd0;
            sha_last_block_q   <= 1'b0;
            sha_lane_valid_q   <= 1'b0;
            s_sampler_done_q   <= 1'b0;

            sampler_cmd_valid  <= 1'b0;
            sampler_cmd_mode   <= 3'd0;
            sampler_cmd_k      <= 3'd0;
            sampler_cmd_seed   <= '0;
            sampler_cmd_transpose <= 1'b0;
            sampler_cmd_eta3   <= 1'b0;
            sampler_cmd_nonce  <= 8'd0;

            ntt_cmd_valid      <= 1'b0;
            ntt_cmd_mode       <= 1'b0;
            ntt_cmd_k          <= 3'd0;
            ntt_cmd_poly_count <= 5'd0;
        end else begin
            // Latency counter: active during command execution
            if (fsm_q != ST_IDLE && fsm_q != ST_DONE) begin
                cycle_cnt_q <= cycle_cnt_q + 1'b1;
            end

            // SHA3-256 lane absorption streaming logic
            if (sha_lane_valid_q && sampler_in_lane_ready) begin
                sha_lane_cnt_q <= sha_lane_cnt_q + 1'b1;
                if (sha_rem_q == 2'd2) begin
                    sha_rem_q <= 2'd0;
                    sha_grp_q <= sha_grp_q + 1'b1;
                end else begin
                    sha_rem_q <= sha_rem_q + 1'b1;
                end
                if (sha_lane_cnt_q + 1'b1 >= full_block_lanes) begin
                    sha_last_block_q <= 1'b1;
                end
                if (sha_lane_cnt_q + 1'b1 == total_sha_lanes) begin
                    sha_lane_valid_q <= 1'b0;
                end
            end

            // Capture H(ek) digest
            if (fsm_q == ST_FINISH_EK_HASH && sampler_digest_valid) begin
                h_ek_q <= sampler_digest_out;
            end

            // Default pulses
            sampler_cmd_valid <= 1'b0;
            ntt_cmd_valid     <= 1'b0;

            case (fsm_q)
                ST_IDLE: begin
                    cycle_cnt_q          <= 32'd0;
                    sha_lane_cnt_q       <= 8'd0;
                    sha_grp_q            <= 6'd0;
                    sha_rem_q            <= 2'd0;
                    sha_last_block_q     <= 1'b0;
                    sha_lane_valid_q     <= 1'b0;
                    s_sampler_done_q     <= 1'b0;
                    ready_q              <= !start;
                    done_q               <= 1'b0;

                    if (start) begin
                        mode_q <= mode;
                        seed_d_q <= seed_d;
                        seed_z_q <= seed_z;
                        k_q         <= k;
                        t_lanes_total_q <= (k == 3'd2) ? 8'd96 : (k == 3'd3) ? 8'd144 : 8'd192;
                        k_invalid_q <= (k < 3'd2 || k > 3'd4);

                        // Start fast direct SHA3-512 command on hash_sampler
                        sampler_cmd_valid <= !mode;
                        sampler_cmd_mode  <= 3'd1; // SHA3-512
                        sampler_cmd_k     <= k;
                        sampler_cmd_seed  <= seed_d;
                        fsm_q             <= mode == 2 ? ST_DECAP : mode != 0 ? ST_ENCAP : ST_SHA512_WAIT;
                    end
                end

                ST_SHA512_WAIT: begin
                    ready_q <= 1'b0;
                    done_q  <= 1'b0;
                    if (sampler_cmd_done) begin
                        rho_q   <= sampler_digest_out;
                        sigma_q <= sampler_digest_out_sigma;
                        fsm_q   <= ST_START_NTT;
                    end
                end

                ST_START_NTT: begin
                    ready_q <= 1'b0;
                    done_q  <= 1'b0;
                    s_sampler_done_q <= 1'b0;
                    // 1. Issue NTT forward command for all 2*k polynomials (s then e)
                    ntt_cmd_valid      <= 1'b1;
                    ntt_cmd_mode       <= 1'b0; // Forward NTT
                    ntt_cmd_k          <= k_q;
                    ntt_cmd_poly_count <= {1'b0, k_q, 1'b0}; // 2*k polynomials

                    // 2. Issue Vector s sampling command to hash_sampler
                    sampler_cmd_valid <= 1'b1;
                    sampler_cmd_mode  <= 3'd3; // VECTOR mode
                    sampler_cmd_k     <= k_q;
                    sampler_cmd_seed  <= sigma_q;
                    sampler_cmd_nonce <= 8'd0;
                    sampler_cmd_eta3  <= (k_q == 3'd2);

                    fsm_q <= ST_SAMPLE_S;
                end

                ST_SAMPLE_S: begin
                    ready_q <= 1'b0;
                    done_q  <= 1'b0;
                    if (sampler_cmd_done) begin
                        s_sampler_done_q <= 1'b1;
                    end
                    if (s_sampler_done_q && (s_fifo_cnt_q == 2'd0)) begin
                        $display("      [k=%0d cycle=%0d] Sample S finished", k_q, cycle_cnt_q);
                        s_sampler_done_q <= 1'b0;
                        // Issue Vector e sampling command to hash_sampler
                        sampler_cmd_valid <= 1'b1;
                        sampler_cmd_mode  <= 3'd3; // VECTOR mode
                        sampler_cmd_k     <= k_q;
                        sampler_cmd_seed  <= sigma_q;
                        sampler_cmd_nonce <= {5'b0, k_q};
                        sampler_cmd_eta3  <= (k_q == 3'd2);

                        fsm_q <= ST_SAMPLE_E;
                    end
                end

                ST_SAMPLE_E: begin
                    ready_q <= 1'b0;
                    done_q  <= 1'b0;
                    if (sampler_cmd_done) begin
                        $display("      [k=%0d cycle=%0d] Sample E finished", k_q, cycle_cnt_q);
                        // Immediately command sampling of Matrix A
                        sampler_cmd_valid <= 1'b1;
                        sampler_cmd_mode  <= 3'd2; // MATRIX mode
                        sampler_cmd_k     <= k_q;
                        sampler_cmd_seed  <= rho_q;
                        sampler_cmd_nonce <= 8'd0;
                        sampler_cmd_eta3  <= 1'b0;
                        sampler_cmd_transpose <= 1'b0;

                        fsm_q          <= ST_SAMPLE_A_AND_MUL;
                        fsm_sample_a_q <= 1'b1;
                    end
                end

                ST_SAMPLE_A_AND_MUL: begin
                    ready_q <= 1'b0;
                    done_q  <= 1'b0;
                    if (all_mat_rows_done) begin
                        $display("      [k=%0d cycle=%0d] Sample A & Mul finished", k_q, cycle_cnt_q);
                        // Initiate fast SHA3-256 for H(pk) using hash_sampler
                        sampler_cmd_valid    <= 1'b1;
                        sampler_cmd_mode     <= 3'd0; // SHA3-256
                        sha_lane_cnt_q       <= 8'd0;
                        sha_grp_q            <= 6'd0;
                        sha_rem_q            <= 2'd0;
                        sha_last_block_q     <= 1'b0;
                        sha_lane_valid_q     <= 1'b1;
                        fsm_q                <= ST_FINISH_EK_HASH;
                        fsm_sample_a_q       <= 1'b0;
                    end
                end

                ST_FINISH_EK_HASH: begin
                    if (sampler_digest_valid) begin
                        $display("      [k=%0d cycle=%0d] Finish EK Hash finished", k_q, cycle_cnt_q);
                        sha_lane_valid_q <= 1'b0;
                        sha_last_block_q <= 1'b0;
                        fsm_q            <= ST_DONE;
                        ready_q          <= 1'b1;
                        done_q           <= 1'b1;
                    end else begin
                        ready_q <= 1'b0;
                        done_q  <= 1'b0;
                    end
                end

                ST_DONE: begin
                    sha_lane_valid_q <= 1'b0;
                    sha_last_block_q <= 1'b0;
                    ready_q          <= !start;
                    done_q           <= !start;
                    if (start) begin
                        mode_q <= mode;
                        // Immediate restart support
                        cycle_cnt_q          <= 32'd0;
                        sha_lane_cnt_q       <= 8'd0;
                        sha_grp_q            <= 6'd0;
                        sha_rem_q            <= 2'd0;

                        seed_d_q <= seed_d;
                        seed_z_q <= seed_z;
                        k_q      <= k;
                        t_lanes_total_q <= (k == 3'd2) ? 8'd96 : (k == 3'd3) ? 8'd144 : 8'd192;

                        sampler_cmd_valid <= !mode;
                        sampler_cmd_mode  <= 3'd1; // SHA3-512
                        sampler_cmd_k     <= k;
                        sampler_cmd_seed  <= seed_d;
                        fsm_q             <= mode == 2 ? ST_DECAP : mode != 0 ? ST_ENCAP : ST_SHA512_WAIT;
                    end
                end

                ST_ENCAP: begin
                    if (enc_complete) begin
                        fsm_q   <= ST_DONE;
                        ready_q <= 1'b1;
                        done_q  <= 1'b1;
                    end else begin
                        ready_q <= 1'b0;
                        done_q  <= 1'b0;
                    end
                end

                ST_DECAP: begin
                    if (enc_complete) begin
                        fsm_q   <= ST_DONE;
                        ready_q <= 1'b1;
                        done_q  <= 1'b1;
                    end else begin
                        ready_q <= 1'b0;
                        done_q  <= 1'b0;
                    end
                end

                default: begin
                    fsm_q   <= ST_IDLE;
                    ready_q <= 1'b1;
                    done_q  <= 1'b0;
                end
            endcase
        end
    end

    // =========================================================================
    // 10. Memory Query & Readout Logic (1-Cycle Synchronous)
    // =========================================================================
    // ek layout: ByteEncode12(t) [k*384 bytes] || rho [32 bytes]
    // dk layout: ByteEncode12(s) [k*384 bytes] || ek [k*384 + 32 bytes] || H(ek) [32 bytes] || z [32 bytes]

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_en_q      <= 1'b0;
            rd_is_dk_q   <= 1'b0;
            rd_addr_q    <= 12'd0;
            mem_rd_valid <= 1'b0;
        end else begin
            rd_en_q      <= mem_rd_en;
            rd_is_dk_q   <= mem_rd_is_dk;
            rd_addr_q    <= mem_rd_addr;
            mem_rd_valid <= mem_rd_en;
        end
    end

    // Helper functions for byte extraction from 48-bit words (4 coeffs)
    function automatic logic [7:0] get_word_byte(input logic [47:0] w, input logic [2:0] sub);
        case (sub)
            3'd0: get_word_byte = w[7:0];
            3'd1: get_word_byte = {w[15:12], w[11:8]};
            3'd2: get_word_byte = w[23:16];
            3'd3: get_word_byte = w[31:24];
            3'd4: get_word_byte = {w[39:36], w[35:32]};
            default: get_word_byte = w[47:40];
        endcase
    endfunction

    wire [4:0] ek_rho_byte_idx = rd_addr_q - pke_bytes;
    wire [4:0] dk_rho_byte_idx = rd_addr_q - pke_bytes - pke_bytes;
    wire [4:0] dk_hek_byte_idx = rd_addr_q - pke_bytes - ek_total_bytes;
    wire [4:0] dk_z_byte_idx   = rd_addr_q - pke_bytes - ek_total_bytes - 12'd32;

    always_comb begin
        mem_rd_data = 8'd0;
        if (mode_q) begin
            mem_rd_data = enc_read_byte;
        end else if (!rd_is_dk_q) begin
            // Reading ek
            if (rd_addr_q < pke_bytes) begin
                mem_rd_data = get_word_byte(pk_word_for_mem, ek_t_sub);
            end else if (rd_addr_q < ek_total_bytes) begin
                mem_rd_data = rho_q[ek_rho_byte_idx*8 +: 8];
            end
        end else begin
            // Reading dk
            if (rd_addr_q < pke_bytes) begin
                mem_rd_data = get_word_byte(ram_s_dk_rdata, dk_s_sub);
            end else if (rd_addr_q < pke_bytes + pke_bytes) begin
                mem_rd_data = get_word_byte(pk_word_for_mem, ek_t_sub);
            end else if (rd_addr_q < pke_bytes + ek_total_bytes) begin
                mem_rd_data = rho_q[dk_rho_byte_idx*8 +: 8];
            end else if (rd_addr_q < pke_bytes + ek_total_bytes + 12'd32) begin
                mem_rd_data = h_ek_q[dk_hek_byte_idx*8 +: 8];
            end else if (rd_addr_q < pke_bytes + ek_total_bytes + 12'd64) begin
                mem_rd_data = seed_z_q[dk_z_byte_idx*8 +: 8];
            end
        end
    end

    // Streaming Key Out Interface (registered boundary outputs)
    logic       key_out_valid_q;
    logic [7:0] key_out_data_q;
    logic       key_out_last_q;
    logic       key_out_is_dk_q;
    assign key_out_valid = key_out_valid_q;
    assign key_out_data  = key_out_data_q;
    assign key_out_last  = key_out_last_q;
    assign key_out_is_dk = key_out_is_dk_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_out_valid_q <= 1'b0;
            key_out_data_q  <= 8'd0;
            key_out_last_q  <= 1'b0;
            key_out_is_dk_q <= 1'b0;
        end else begin
            key_out_valid_q <= 1'b0;
            key_out_data_q  <= 8'd0;
            key_out_last_q  <= 1'b0;
            key_out_is_dk_q <= 1'b0;
        end
    end

    // Subordinate datapath includes for encapsulation and decapsulation operations
    `include "mlkem_encap_datapath.svh"
    `include "mlkem_decap_datapath.svh"

endmodule
