//=============================================================================
// File: mlkem_encap_datapath.svh
// Description: ML-KEM Encapsulation (Encap) Datapath and Control Subsystem.
//              Included within `mlkem_keygen_top.sv`.
//
// Target Standard: FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Operation Modes:
//   - Mode 1: ML-KEM Encapsulation (Encap(pk) -> (c, K))
//   - Mode 2: ML-KEM Decapsulation Re-Encryption (FO Transform Re-Encap c' = Encap(pk, m'))
//
// Security Levels Supported:
//   - ML-KEM-512  (k=2, eta1=3, eta2=2, d_u=10, d_v=4)
//   - ML-KEM-768  (k=3, eta1=2, eta2=2, d_u=10, d_v=4)
//   - ML-KEM-1024 (k=4, eta1=2, eta2=2, d_u=11, d_v=5)
//
// Complete Encapsulation Algorithmic Workflow & FSM State Machine:
//   FSM States (enc_state_t):
//   --------------------------------------------------------------------------
//   Index | Symbolic Name   | Mathematical Operation & Architectural Action
//   --------------------------------------------------------------------------
//   EC_0  | EC_IDLE         | Standby / inactive state waiting for `enc_start`.
//   EC_1  | EC_HASH_CMD     | Issue SHA3-256 command to compute H(pk) = H(ek).
//   EC_2  | EC_LOAD         | Stream in public key ek = (t_hat || rho), decode 12-bit
//         |                 | coefficients via `poly_decode12_lane`, stream to Keccak,
//         |                 | extract seed rho, and await SHA3-256 digest H(pk).
//   EC_3  | EC_G_CMD        | Issue SHA3-512 command for G(m || H(pk)) using 32-byte
//         |                 | random message m and 32-byte hash H(pk).
//   EC_4  | EC_G_WAIT       | Await SHA3-512 digest: derives 256-bit shared key K
//         |                 | (`enc_secret_q`) and 256-bit randomness seed r / coins (`enc_coins_q`).
//   EC_5  | EC_R_CMD        | Issue PRF/CBD_eta1 sampler command with seed `enc_coins_q`
//         |                 | to sample ephemeral secret error vector r in R_q^k.
//   EC_6  | EC_R            | Sample vector r, store in memory, launch NTT core
//         |                 | to compute r_hat = NTT(r) across k polynomials.
//   EC_7  | EC_E1_CMD       | Issue PRF/CBD_eta2 command to sample error vector e_1.
//   EC_8  | EC_E1           | Sample error vector e_1 (k polynomials), store in `ram_e`.
//   EC_9  | EC_E2_CMD       | Issue PRF/CBD_eta2 command to sample scalar error e_2.
//   EC_10 | EC_E2           | Sample error e_2, pipeline-add message encoding
//         |                 | (m * round(q/2) = 1665 mod q), store into `enc_e2_ram`.
//   EC_11 | EC_MATRIX_CMD   | Issue XOF / SHAKE128 command to generate public matrix
//         |                 | A^T from seed rho on-the-fly.
//   EC_12 | EC_MATRIX       | Compute vector u_hat = A^T * r_hat in NTT domain using
//         |                 | pipelined MAC units and accumulate partial products.
//   EC_13 | EC_V            | Compute inner product v_hat = t_hat^T * r_hat in NTT
//         |                 | domain using decoded public key polynomials t_hat.
//   EC_14 | EC_DRAIN        | Drain and flush multiplier accumulation pipelines.
//   EC_15 | EC_FINISH       | Encapsulation complete: ciphertext (u, v) encoded,
//         |                 | streamed via `ct_out_*` and retained in `enc_ct_ram`.
//   EC_16 | EC_FAIL         | Fatal error / abort state (invalid parameters, modulus
//         |                 | violations in public key, or framing mismatch).
//   EC_17 | EC_DEC_WAIT     | Decapsulation standby: waits for `dec_kick` to trigger
//         |                 | re-encryption during Decap Fujisaki-Okamoto transform.
//
// Key Hardware Resource Sharing:
//   - Keccak/Sampler, NTT Transform core, Modular Multiplier, and Public-Key RAMs
//     are dynamically shared with KeyGen and Decap to minimize FPGA area.
//   - Distributed RAM structures provide parallel, conflict-free access during
//     matrix-vector multiplication and ciphertext encoding.
//=============================================================================

// Encapsulation control inside mlkem_keygen_top. The sampler, transform engine,
// multiplier, accumulation pipeline, r/e RAMs and public-key banks are shared
// with KeyGen. Only inverse-input staging, e2 and ciphertext retention are new.

// ----------------------------------------------------------------------------
// Encapsulation Finite State Machine (FSM) State Type Definition
// States 0 through 17 cover full lifecycle of ML-KEM encapsulation & FO re-encap.
// ----------------------------------------------------------------------------
typedef enum logic [4:0] {
    EC_IDLE,       // EC_0:  Idle / standby state
    EC_HASH_CMD,   // EC_1:  Issue H(pk) hash command to Keccak core
    EC_LOAD,       // EC_2:  Stream & decode public key ek=(t_hat || rho), compute H(pk)
    EC_G_CMD,      // EC_3:  Issue G(m || H(pk)) command to Keccak core
    EC_G_WAIT,     // EC_4:  Wait for G hash digest -> shared key K and seed r
    EC_R_CMD,      // EC_5:  Issue PRF/CBD sampler command for ephemeral error vector r
    EC_R,          // EC_6:  Sample vector r, write RAM, trigger forward NTT(r)
    EC_E1_CMD,     // EC_7:  Issue PRF/CBD sampler command for error vector e_1
    EC_E1,         // EC_8:  Sample error vector e_1, store in ram_e
    EC_E2_CMD,     // EC_9:  Issue PRF/CBD sampler command for error scalar e_2
    EC_E2,         // EC_10: Sample e_2, add message offset (round(q/2)=1665), store in enc_e2_ram
    EC_MATRIX_CMD, // EC_11: Issue XOF matrix generation command using seed rho
    EC_MATRIX,     // EC_12: On-the-fly Matrix A^T expansion & vector-matrix multiply (A^T * r)
    EC_V,          // EC_13: Vector inner product v_hat = t_hat^T * r_hat in NTT domain
    EC_DRAIN,      // EC_14: Pipeline drain for accumulation and inverse NTT staging
    EC_FINISH,     // EC_15: Successful encapsulation completion state
    EC_FAIL,       // EC_16: Abort / error trap state
    EC_DEC_WAIT    // EC_17: Decapsulation re-encryption hold state (awaits dec_kick)
} enc_state_t;
enc_state_t enc_state_q;

// Ciphertext emission and status signals
wire enc_emit;              // Strobe indicating a completed ciphertext chunk is emitted
wire [87:0] enc_ct_data;     // Packed ciphertext output group from poly_encode_pair
wire [3:0] enc_ct_bytes_out; // Number of valid bytes in current ciphertext group

// NTT transform control flags (0: FWD cmd, 1: FWD run, 2: INV cmd, 3: INV run)
logic [1:0] enc_ntt_state_q; // 0 forward command, 1 forward, 2 inverse command, 3 inverse
assign enc_inverse = enc_ntt_state_q[1]; // Bit 1 indicates inverse NTT operation
assign enc_abort = enc_active && (enc_state_q == EC_FAIL);
assign enc_complete = enc_state_q == EC_FINISH || enc_state_q == EC_FAIL;

// Error detection and status aggregation
logic enc_error_q, pk_error_q;
wire enc_err_comb = enc_error_q || pk_error_q;
logic enc_err_comb_q;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) enc_err_comb_q <= 1'b0;
    else if (clr_state) enc_err_comb_q <= 1'b0;
    else enc_err_comb_q <= enc_err_comb;
end
assign operation_error = enc_err_comb && mode_q != 0;

// Security parameters and seed registers
logic [255:0] enc_message_q, enc_message_shift_q, enc_rho_q, enc_coins_q;
logic [255:0] enc_secret_q;

// Shared key output multiplexer: select shared secret K or implicit rejection key
assign shared_secret = !done || enc_err_comb ? 256'd0 :
                       (mode_q == 2 && dec_mismatch ? dec_reject : enc_secret_q);

// Flow control, lane counters, and credit registers
logic [7:0] enc_load_lane_q;        // Current 64-bit word lane during pk ingestion
logic [3:0] enc_raw_ready_q;        // Ready status flags for raw sampled polynomials
logic [4:0] enc_product_ready_q;    // Ready status flags for vector-matrix product polynomials
logic [8:0] enc_raw_words_q, enc_product_words_q;
logic [8:0] enc_raw_credit_q;       // Credit counter for raw r words available for NTT
logic       enc_raw_has_word_q;     // Flag: raw r words ready to be read
logic [8:0] enc_product_credit_q;   // Credit counter for matrix product words available for INTT
logic       enc_product_has_word_q; // Flag: product words available
logic       enc_feed_poly_lt_k_q;   // Helper flag: feeding polynomial index < k
logic       enc_feed_poly_le_k_q;   // Helper flag: feeding polynomial index <= k
logic       enc_mul_col_is_last_q;  // Last column indicator in vector-matrix multiplication
logic       enc_mul_beat_is_63_q;   // Beat 63 (last coefficient pair) in 64-beat polynomial cycle
logic       enc_is_matrix_q;        // FSM active in Matrix A^T * r multiplication
logic [2:0] enc_mul_row_q;          // Current row index of Matrix A^T
logic [2:0] enc_encode_poly_q;      // Index of polynomial currently undergoing compression/encoding
logic       enc_encode_poly_is_k_q; // Indicates processing of scalar v polynomial (index == k)
logic [7:0] enc_ct_group_q;         // Output ciphertext group counter
logic [2:0] enc_ct_poly_q;          // Ciphertext polynomial tracking counter
logic       enc_ct_poly_is_k_q;     // Flag: ciphertext polynomial reached k (v component)
logic [3:0] enc_du_q;               // Ciphertext u compression bitwidth d_u (10 or 11)
logic [3:0] enc_dv_q;               // Ciphertext v compression bitwidth d_v (4 or 5)

// Public key ingestion parameters based on security parameter k
logic [7:0] enc_t_lanes_q;          // Total 64-bit lanes for public vector t_hat
logic [7:0] enc_total_lanes_q;      // Total lanes for entire public key (t_hat || rho)
logic [7:0] enc_penultimate_lanes_q;// Second to last lane threshold
logic [7:0] enc_full_block_lanes_q; // Keccak block boundary lane index
logic       enc_loading_t_q;        // Flag: currently receiving t_hat coefficients
logic       enc_load_done_q;        // Flag: public key ingestion finished
logic       enc_is_last_lane_q;     // Flag: currently on the final 64-bit lane of ek
logic       enc_lane_last_block_q;  // Keccak rate block padding boundary

// Security level parameter decode upon start_pulse
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        enc_t_lanes_q               <= 8'd0;
        enc_total_lanes_q           <= 8'd0;
        enc_penultimate_lanes_q     <= 8'd0;
        enc_full_block_lanes_q      <= 8'd0;
        enc_du_q                    <= 4'd10;
        enc_dv_q                    <= 4'd4;
    end else if (start_pulse) begin
        // Configure compression bitwidths according to FIPS 203:
        // ML-KEM-1024 (k=4): d_u = 11, d_v = 5; ML-KEM-512/768: d_u = 10, d_v = 4
        enc_du_q <= (k == 3'd4) ? 4'd11 : 4'd10;
        enc_dv_q <= (k == 3'd4) ? 4'd5  : 4'd4;
        case (k)
            3'd2: begin // ML-KEM-512: 2 polynomials in t_hat
                enc_t_lanes_q               <= 8'd96;
                enc_total_lanes_q           <= 8'd100;
                enc_penultimate_lanes_q     <= 8'd98;
                enc_full_block_lanes_q      <= 8'd85;
            end
            3'd3: begin // ML-KEM-768: 3 polynomials in t_hat
                enc_t_lanes_q               <= 8'd144;
                enc_total_lanes_q           <= 8'd148;
                enc_penultimate_lanes_q     <= 8'd146;
                enc_full_block_lanes_q      <= 8'd136;
            end
            default: begin // ML-KEM-1024: 4 polynomials in t_hat
                enc_t_lanes_q               <= 8'd192;
                enc_total_lanes_q           <= 8'd196;
                enc_penultimate_lanes_q     <= 8'd194;
                enc_full_block_lanes_q      <= 8'd187;
            end
        endcase
    end
end

wire enc_loading_t = enc_loading_t_q;
assign enc_lane_last_block = enc_lane_last_block_q;
wire enc_decoder_ready, enc_pk_valid, enc_pk_bad;
logic enc_load_phase_q;

// Public key load phase management
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        enc_load_phase_q <= 1'b0;
    end else if (start_pulse || enc_abort) begin
        enc_load_phase_q <= 1'b0;
    end else begin
        if (enc_state_q == EC_HASH_CMD && sampler_cmd_ready && (k_q >= 2 && k_q <= 4))
            enc_load_phase_q <= 1'b1;
        else if (enc_state_q == EC_LOAD && sampler_digest_valid)
            enc_load_phase_q <= 1'b0;
    end
end

wire enc_load_phase = enc_load_phase_q;
assign enc_lane_valid = enc_load_phase_q && !enc_load_done_q &&
                      ek_in_valid && (!enc_loading_t_q || enc_decoder_ready);
assign ek_in_ready = enc_load_phase_q && !enc_load_done_q &&
                     sampler_in_lane_ready && (!enc_loading_t_q || enc_decoder_ready);
wire enc_load_fire = ek_in_valid && ek_in_ready;
assign enc_pk_write = enc_active && enc_pk_valid;

// 12-bit public key polynomial coefficient decoder (deserializes 64-bit lanes to 12-bit words)
poly_decode12_lane enc_pk_decoder (
    .clk(clk), .rst_n(rst_n), .clear(start_pulse || enc_abort),
    .in_valid(dec_compute ? dec_pk_write : enc_load_fire && enc_loading_t), .in_ready(enc_decoder_ready),
    .in_data(dec_compute ? dk_in_data : ek_in_data), .out_valid(enc_pk_valid), .out_ready(1'b1),
    .out_data(enc_pk_word), .out_bad(enc_pk_bad)
);

// ----------------------------------------------------------------------------
// Keccak / Sampler Command Generation Logic
// Formulates command parameters based on active FSM state.
// ----------------------------------------------------------------------------
// Commands remain asserted, with stable payload, until accepted.
always_comb begin
    enc_s_cmd_valid = enc_active;
    enc_s_mode = 3'd3;            // Default: CBD sampling mode
    enc_s_k = k_q;                // Number of polynomials k
    enc_s_seed = enc_coins_q;     // Seed coins derived from G(m || H(pk))
    enc_s_nonce = 0;
    enc_s_eta3 = 0;
    case (enc_state_q)
        EC_HASH_CMD: begin enc_s_mode = 0; enc_s_seed = 0; end // Mode 0: SHA3-256 for H(pk)
        EC_G_CMD: begin enc_s_mode = 5; enc_s_seed = enc_message_q; end // Mode 5: SHA3-512 for G(m || H(pk))
        EC_R_CMD: enc_s_eta3 = k_q == 2; // For ML-KEM-512, eta1 = 3 (eta3 flag asserted)
        EC_E1_CMD: enc_s_nonce = {5'd0,k_q}; // Nonce offset for error vector e_1
        EC_E2_CMD: begin enc_s_nonce = {4'd0,k_q,1'b0}; enc_s_k = 1; end // Scalar error e_2 (single poly)
        EC_MATRIX_CMD: begin enc_s_mode = 2; enc_s_seed = enc_rho_q; end // Mode 2: SHAKE128 for Matrix A^T
        default: enc_s_cmd_valid = 0;
    endcase
end

// Multiplier column sequencing and matrix operand tracking
wire [1:0] enc_next_col = (enc_mul_beat_is_63_q && enc_mul_valid && mul_s_ready) ?
                          (enc_mul_col_is_last_q ? 2'd0 : enc_mul_col_q[1:0] + 1'b1) :
                          enc_mul_col_q[1:0];
logic enc_operand_ready_q;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        enc_operand_ready_q <= 1'b0;
    end else if (start_pulse) begin
        enc_operand_ready_q <= 1'b0;
    end else begin
        enc_operand_ready_q <= s_ready_mask_q[enc_next_col];
    end
end
wire enc_operand_ready = enc_operand_ready_q;
assign enc_mat_req_ready = enc_is_matrix_q && enc_operand_ready;
assign enc_mat_ready     = enc_mat_req_ready && mul_s_ready;
assign enc_out_ready     = enc_is_matrix_q ? enc_mat_ready : 1'b1;
wire enc_sample_fire = enc_active &&
                       (enc_is_matrix_q ? (sampler_mat_valid && sampler_mat_ready) : sampler_vec_valid);

// Sampler RAM write enable strobes for vectors r, e_1, and scalar e_2
assign enc_r_write  = enc_active && (enc_state_q == EC_R)  && sampler_vec_valid;
assign enc_e1_write = enc_active && (enc_state_q == EC_E1) && sampler_vec_valid;
wire   enc_e2_write = enc_active && (enc_state_q == EC_E2) && sampler_vec_valid;

// ----------------------------------------------------------------------------
// Internal Distributed RAM Storage
// ----------------------------------------------------------------------------
// Error polynomial e_2 RAM: Holds 64 words x 48 bits (256 12-bit coefficients)
(* ram_style = "distributed" *) logic [47:0] enc_e2_ram [0:63];

// Vector-matrix product RAMs: 5 explicit 64-entry banks to eliminate multiplexer stalls
// 5 explicit 64-entry banks to prevent interslice read-modify-write data multiplexing
(* ram_style = "distributed" *) logic [47:0] enc_product_ram_b0 [0:63];
(* ram_style = "distributed" *) logic [47:0] enc_product_ram_b1 [0:63];
(* ram_style = "distributed" *) logic [47:0] enc_product_ram_b2 [0:63];
(* ram_style = "distributed" *) logic [47:0] enc_product_ram_b3 [0:63];
(* ram_style = "distributed" *) logic [47:0] enc_product_ram_b4 [0:63];

// Retained ciphertext RAM: 160 entries x 88 bits (holds full serialized ciphertext)
(* ram_style = "distributed" *) logic [87:0] enc_ct_ram [0:159];

logic [7:0] enc_read_group;
logic [3:0] enc_read_sub;

// Dedicated dual-read-ports for enc_ct_ram:
// Port A: internal comparison/packing during decapsulation verification
wire [7:0] enc_ct_core_raddr = dec_compute ? dec_pack_group_q : enc_ct_group_q;
assign dec_compare_word      = enc_ct_ram[enc_ct_core_raddr];

// Port B: host query readout (completely decoupled from internal pipeline)
wire [87:0] enc_read_word    = enc_ct_ram[enc_read_group];

// ----------------------------------------------------------------------------
// Pipelined Message Modulation & Error Addition for Scalar e_2
// Implements: e_2' = e_2 + round(q/2) * m mod q
// where round(q/2) = round(3329/2) = 1665.
// Stage 1: Pipeline registration of sampler data and message bits.
// Stage 2: Modular addition of 1665 for asserted message bits.
// Stage 3: Synchronous write into enc_e2_ram.
// ----------------------------------------------------------------------------
// Pipelined message addition: Stage 1 registers sampler output and message shift;
// Stage 2 computes 12-bit modular addition with 1665 offset; Stage 3 writes enc_e2_ram.
logic        enc_e2_we1_q, enc_e2_we_q;
logic [5:0]  enc_e2_waddr1_q, enc_e2_waddr_q;
logic [47:0] enc_e2_raw_q;
logic [3:0]  enc_e2_shift_q;
logic [47:0] enc_e2_wdata_q;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        enc_e2_we1_q    <= 1'b0;
        enc_e2_waddr1_q <= 6'd0;
        enc_e2_raw_q    <= 48'd0;
        enc_e2_shift_q  <= 4'd0;
        enc_e2_we_q     <= 1'b0;
        enc_e2_waddr_q  <= 6'd0;
        enc_e2_wdata_q  <= 48'd0;
    end else begin
        // Stage 1: Register sampled e_2 coefficient chunk and message bits
        enc_e2_we1_q    <= enc_e2_write;
        enc_e2_waddr1_q <= enc_sample_beat_q;
        enc_e2_raw_q    <= sampler_out_data;
        enc_e2_shift_q  <= enc_message_shift_q[3:0];

        // Stage 2: Parallel modular addition of 1665 across 4 coefficient lanes
        enc_e2_we_q     <= enc_e2_we1_q;
        enc_e2_waddr_q  <= enc_e2_waddr1_q;
        for (integer em=0; em<4; em=em+1) begin
            enc_e2_wdata_q[12*em +: 12] <= add_q(enc_e2_raw_q[12*em +: 12],
                                                 enc_e2_shift_q[em] ? 12'd1665 : 12'd0);
        end
    end
end

// Bank and address decoding for product RAMs
wire [2:0]  enc_prod_wbank  = dec_u_write ? {1'b0, dec_u_addr[7:6]} : {1'b0, p3_row};
wire [5:0]  enc_prod_waddr  = dec_u_write ? dec_u_addr[5:0] : p3_beat;
wire [47:0] enc_prod_wdata  = dec_u_write ? dec_u_data : p3_final;
wire        enc_prod_we     = dec_u_write || (enc_active && p3_valid && p3_is_last_col);

// Synchronous RAM write process for e_2, product banks, and retained ciphertext
always_ff @(posedge clk) begin
    if (dec_v_write) enc_e2_ram[dec_v_addr] <= dec_v_data;
    else if (enc_e2_we_q) enc_e2_ram[enc_e2_waddr_q] <= enc_e2_wdata_q;

    if (enc_prod_we && enc_prod_wbank == 3'd0) enc_product_ram_b0[enc_prod_waddr] <= enc_prod_wdata;
    if (enc_prod_we && enc_prod_wbank == 3'd1) enc_product_ram_b1[enc_prod_waddr] <= enc_prod_wdata;
    if (enc_prod_we && enc_prod_wbank == 3'd2) enc_product_ram_b2[enc_prod_waddr] <= enc_prod_wdata;
    if (enc_prod_we && enc_prod_wbank == 3'd3) enc_product_ram_b3[enc_prod_waddr] <= enc_prod_wdata;
    if (enc_prod_we && enc_prod_wbank == 3'd4) enc_product_ram_b4[enc_prod_waddr] <= enc_prod_wdata;

    if (ct_in_valid && ct_in_ready) enc_ct_ram[dec_ct_groups_q] <= ct_in_data;
    else if (enc_emit) enc_ct_ram[enc_ct_group_q] <= enc_ct_data;
end

// ----------------------------------------------------------------------------
// NTT Engine Control and Flow Credit Architecture
// Manages forward transform on vector r, and inverse transforms on u_hat and v_hat.
// Overlaps generation, transform, and multiplication via asynchronous credit counters.
// ----------------------------------------------------------------------------
// Raw r is read before its address is overwritten by the forward transform.
// Three internal NTT slots overlap loading, calculation and output.
assign enc_n_cmd_valid = enc_active &&
    ((enc_ntt_state_q == 0 && enc_state_q == EC_R_CMD) || enc_ntt_state_q == 2);
assign enc_n_polys = enc_inverse ? {2'd0,k_q}+5'd1 : {2'd0,k_q}; // (k+1) polynomials for INTT (u + v)
assign enc_n_valid = enc_active &&
    ((enc_ntt_state_q == 2'd1 && enc_feed_poly_lt_k_q && enc_raw_has_word_q) ||
     (enc_ntt_state_q == 2'd3 && enc_feed_poly_le_k_q && enc_product_has_word_q));

// Flow credit tracking for raw sampled r words feeding forward NTT
wire raw_inc = enc_r_write;
wire raw_dec = enc_n_valid && ntt_in_ready && enc_feed_pair_q[0] && (enc_ntt_state_q == 2'd1);

logic next_raw_has_word;
always_comb begin
    case ({raw_inc, raw_dec})
        2'b10:   next_raw_has_word = 1'b1;
        2'b01:   next_raw_has_word = |enc_raw_credit_q[8:1];
        default: next_raw_has_word = enc_raw_has_word_q;
    endcase
end

// Flow credit tracking for product words feeding inverse NTT
wire prod_inc = p3_valid && p3_is_last_col;
wire prod_dec = enc_n_valid && ntt_in_ready && (enc_ntt_state_q == 2'd3);

logic next_product_has_word;
always_comb begin
    case ({prod_inc, prod_dec})
        2'b10:   next_product_has_word = 1'b1;
        2'b01:   next_product_has_word = |enc_product_credit_q[8:1];
        default: next_product_has_word = enc_product_has_word_q;
    endcase
end

// Read multiplexer selecting product RAM banks b0-b4 based on polynomial index
logic [47:0] enc_product_word_mux;
always_comb begin
    case (feed_word_addr_q[8:6])
        3'd0: enc_product_word_mux = enc_product_ram_b0[feed_word_addr_q[5:0]];
        3'd1: enc_product_word_mux = enc_product_ram_b1[feed_word_addr_q[5:0]];
        3'd2: enc_product_word_mux = enc_product_ram_b2[feed_word_addr_q[5:0]];
        3'd3: enc_product_word_mux = enc_product_ram_b3[feed_word_addr_q[5:0]];
        default: enc_product_word_mux = enc_product_ram_b4[feed_word_addr_q[5:0]];
    endcase
end
assign enc_product_word = enc_product_word_mux;

// Feed word multiplexer: select product RAM for inverse NTT or raw r for forward NTT
wire [47:0] enc_feed_word = enc_inverse ? enc_product_word : ram_s_query_rdata;
assign enc_n_data = enc_feed_pair_q[0] ? enc_feed_word[47:24] : enc_feed_word[23:0];
assign enc_n_last = enc_inverse ? enc_feed_pair_q == 126 : enc_feed_pair_q == 127;
assign enc_n_poly = {1'b0,enc_feed_poly_q};

// ----------------------------------------------------------------------------
// Pipelined Modular Multiplier Interface
// Computes u_hat = A^T * r_hat (Matrix mode) and v_hat = t_hat^T * r_hat (V mode)
// ----------------------------------------------------------------------------
logic enc_mul_rst_q;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        enc_mul_rst_q <= 1'b1;
    else
        enc_mul_rst_q <= enc_abort || !(enc_state_q == EC_MATRIX_CMD || enc_state_q == EC_MATRIX || enc_state_q == EC_V || enc_state_q == EC_DRAIN);
end
assign enc_mul_rst = enc_mul_rst_q;
assign enc_mul_valid = enc_active &&
    ((enc_is_matrix_q && sampler_mat_valid && enc_operand_ready) ||
     enc_is_v_q);

// Select operand b: public key word (for v_hat) or on-the-fly sampled matrix A^T
always_comb begin
    case (enc_mul_beat_q[1:0])
        0: enc_pk_mul_word = enc_w0;
        1: enc_pk_mul_word = enc_w1;
        2: enc_pk_mul_word = enc_w2;
        default: enc_pk_mul_word = enc_w3;
    endcase
end
assign enc_mul_b = enc_is_v_q ? enc_pk_mul_word : sampler_mat_data;

// ----------------------------------------------------------------------------
// Post-Processing Pipeline: Noise Addition, Compression, and Serialization
// Dual-lane post-processing handles 2 coefficients per clock cycle from INTT:
//   u = Compress_du(INTT(u_hat) + e_1)
//   v = Compress_dv(INTT(v_hat) + e_2 + MessageOffset)
// ----------------------------------------------------------------------------
// Two field-add/compress lanes match the transform's two-coefficient output.
wire [47:0] enc_e2_read_word = enc_e2_ram[dec_compute ? dec_result_pair_q[6:1] : enc_result_pair_q[6:1]];
wire [47:0] enc_noise_word = ntt_out_poly_index == {1'b0,k_q} ? enc_e2_read_word :
                             ram_e_accum_rdata;
wire [23:0] enc_noise_pair = enc_result_pair_q[0] ? enc_noise_word[47:24] : enc_noise_word[23:0];
logic [1:0] enc_add_ready, enc_add_valid, enc_add_last, enc_compress_ready, enc_compress_valid, enc_compress_last;
wire [11:0] enc_added [0:1];
wire [10:0] enc_compressed [0:1];
logic [3:0] enc_noise_done_q;
logic enc_e2_done_q;
wire enc_noise_ready = ntt_out_poly_index == {1'b0,k_q} ? enc_e2_done_q : enc_noise_done_q[ntt_out_poly_index[1:0]];
assign enc_result_ready = dec_compute ? 1'b1 : (&enc_add_ready && enc_noise_ready);

// Track completion of noise sampling for synchronization with INTT completion
always_ff @(posedge clk) begin
    if (!rst_n || start_pulse) begin enc_noise_done_q <= 0; enc_e2_done_q <= 0; end
    else begin
        if (enc_e1_write && sampler_out_last) enc_noise_done_q[sampler_out_poly_index[1:0]] <= 1;
        if (enc_e2_we_q && enc_e2_waddr_q == 63) enc_e2_done_q <= 1;
    end
end
wire [3:0] enc_du = enc_du_q;
wire [3:0] enc_dv = enc_dv_q;
wire enc_encoder_ready;
wire enc_codec_rst_n = rst_n && !start_pulse && !enc_abort;

// Pipeline staging registers for post-processing operands (Encapsulation)
logic        enc_pp_valid_q;
logic [23:0] enc_pp_a_q;
logic [23:0] enc_pp_b_q;
logic        enc_pp_last_q;
logic [3:0]  enc_pp_d_q;

always_ff @(posedge clk or negedge enc_codec_rst_n) begin
    if (!enc_codec_rst_n) begin
        enc_pp_valid_q <= 1'b0;
        enc_pp_a_q     <= 24'd0;
        enc_pp_b_q     <= 24'd0;
        enc_pp_last_q  <= 1'b0;
        enc_pp_d_q     <= 4'd0;
    end else begin
        enc_pp_valid_q <= enc_active && !dec_compute && enc_inverse && ntt_out_valid && ntt_out_ready;
        if (enc_active && !dec_compute && enc_inverse && ntt_out_valid && ntt_out_ready) begin
            enc_pp_a_q     <= ntt_out_data;
            enc_pp_b_q     <= enc_noise_pair;
            enc_pp_last_q  <= ntt_out_last;
            enc_pp_d_q     <= ntt_out_poly_index == {1'b0,k_q} ? enc_dv_q : enc_du_q;
        end
    end
end

// Pipeline staging registers for post-processing operands (Decapsulation subtraction)
logic        dec_pp_valid_q;
logic [23:0] dec_pp_a_q;
logic [23:0] dec_pp_b_q;
logic        dec_pp_last_q;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dec_pp_valid_q <= 1'b0;
        dec_pp_a_q     <= 24'd0;
        dec_pp_b_q     <= 24'd0;
        dec_pp_last_q  <= 1'b0;
    end else if (start_pulse || enc_abort) begin
        dec_pp_valid_q <= 1'b0;
        dec_pp_a_q     <= 24'd0;
        dec_pp_b_q     <= 24'd0;
        dec_pp_last_q  <= 1'b0;
    end else begin
        dec_pp_valid_q <= dec_compute && dec_n_inverse && ntt_out_valid && ntt_out_ready;
        if (dec_compute && dec_n_inverse && ntt_out_valid && ntt_out_ready) begin
            dec_pp_a_q    <= dec_v_pair;
            dec_pp_b_q    <= ntt_out_data;
            dec_pp_last_q <= ntt_out_last;
        end
    end
end

// Generate dual arithmetic/compressor blocks matching the two-coefficient output stream
for (genvar el=0; el<2; el++) begin: ENC_POSTPROCESS
    wire dec_sub_valid, dec_sub_last;
    wire [11:0] dec_sub_data;

    // Field subtraction for decapsulation: computes v - s^T * u
    field_sub decrypt_subtract (
        .clk(clk), .rst_n(enc_codec_rst_n),
        .in_valid(dec_pp_valid_q), .in_ready(),
        .in_a(dec_pp_a_q[12*el +:12]), .in_b(dec_pp_b_q[12*el +:12]), .in_last(dec_pp_last_q),
        .out_valid(dec_sub_valid), .out_ready(1'b1), .out_data(dec_sub_data), .out_last(dec_sub_last)
    );

    // Modular addition of error noise polynomials (e_1 and e_2) to INTT results
    field_add add_noise (
        .clk(clk), .rst_n(enc_codec_rst_n),
        .in_valid(enc_pp_valid_q), .in_ready(enc_add_ready[el]),
        .in_a(enc_pp_a_q[12*el +: 12]), .in_b(enc_pp_b_q[12*el +: 12]), .in_last(enc_pp_last_q),
        .out_valid(enc_add_valid[el]), .out_ready(enc_compress_ready[el]),
        .out_data(enc_added[el]), .out_last(enc_add_last[el])
    );

    // Hardware Polynomial Compressor: maps 12-bit ring elements to d bits
    mlkem_poly_compress compress (
        .clk(clk), .rst_n(enc_codec_rst_n),
        .s_axis_tvalid(dec_compute ? dec_sub_valid : enc_add_valid[el]), .s_axis_tready(enc_compress_ready[el]),
        .s_axis_tdata({4'd0,dec_compute ? dec_sub_data : enc_added[el]}), .s_axis_td(dec_compute ? 4'd1 : enc_pp_d_q), .s_axis_tlast(dec_compute ? dec_sub_last : enc_add_last[el]),
        .m_axis_tvalid(enc_compress_valid[el]), .m_axis_tready(enc_encoder_ready),
        .m_axis_tdata(enc_compressed[el]), .m_axis_tlast(enc_compress_last[el])
    );
end

// Serialize and pack compressed coefficient pairs into byte-aligned 88-bit output words
wire enc_encoded_valid, enc_encoded_last;
poly_encode_pair enc_encoder (
    .clk(clk), .rst_n(enc_codec_rst_n),
    .cfg_d(enc_encode_poly_is_k_q ? enc_dv_q : enc_du_q),
    .in_valid(&enc_compress_valid && !dec_compute), .in_ready(enc_encoder_ready),
    .in_data({enc_compressed[1],enc_compressed[0]}), .in_last(enc_compress_last[0]),
    .out_valid(enc_encoded_valid), .out_ready(1'b1), .out_data(enc_ct_data),
    .out_bytes(enc_ct_bytes_out), .out_last(enc_encoded_last)
);
assign enc_emit = enc_active && enc_encoded_valid && !enc_err_comb_q;

// ----------------------------------------------------------------------------
// Ciphertext Streaming Output Interface
// Streams packed ciphertext bytes directly to external interface during Mode 1.
// ----------------------------------------------------------------------------
logic        ct_out_valid_q;
logic [87:0] ct_out_data_q;
logic [3:0]  ct_out_bytes_q;
logic        ct_out_last_q;
assign ct_out_valid = ct_out_valid_q;
assign ct_out_data  = ct_out_data_q;
assign ct_out_bytes = ct_out_bytes_q;
wire enc_ct_last    = enc_encoded_last && enc_ct_poly_is_k_q;
assign ct_out_last  = ct_out_last_q;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || start_pulse) begin
        ct_out_valid_q <= 1'b0;
        ct_out_data_q  <= 88'd0;
        ct_out_bytes_q <= 4'd0;
        ct_out_last_q  <= 1'b0;
    end else begin
        ct_out_valid_q <= enc_emit && (mode_q == 2'd1);
        ct_out_data_q  <= (mode_q == 2'd1) ? enc_ct_data : 88'd0;
        ct_out_bytes_q <= (mode_q == 2'd1) ? enc_ct_bytes_out : 4'd0;
        ct_out_last_q  <= enc_ct_last && (mode_q == 2'd1);
    end
end

// ----------------------------------------------------------------------------
// Retained Ciphertext Readout and Exact Reciprocal Division
// Enables host interface to access any arbitrary byte of ciphertext c or
// shared key K after encapsulation finishes.
// ----------------------------------------------------------------------------
// Retained ciphertext: single 88-bit LUTRAM read port followed by byte selector.
// Runtime division using exact reciprocal multiplication.
wire [10:0] enc_u_bytes = k_q == 4 ? 11'd1408 : k_q == 3 ? 11'd960 : 11'd640;
wire [10:0] enc_ct_bytes = enc_u_bytes + (k_q == 4 ? 11'd160 : 11'd128);
wire [11:0] enc_v_addr = rd_addr_q - {1'b0,enc_u_bytes};

    // Fast integer division by 11 using 12-bit fixed-point reciprocal multiplication
    function automatic logic [7:0] div11_12b(input logic [11:0] a);
        logic [25:0] p;
        p = {a, 12'b0} + {a, 10'b0} + {a, 9'b0} + {a, 8'b0} + {a, 6'b0} + {a, 2'b0} + {a, 1'b0};
        div11_12b = p[23:16];
    endfunction

    // Fast integer division by 10 using 12-bit fixed-point reciprocal multiplication
    function automatic logic [7:0] div10_12b(input logic [11:0] a);
        logic [25:0] p;
        p = {a, 12'b0} + {a, 11'b0} + {a, 8'b0} + {a, 7'b0} + {a, 4'b0} + {a, 3'b0} + {a, 1'b0};
        div10_12b = p[23:16];
    endfunction

    // Fast integer division by 5 using 12-bit fixed-point reciprocal multiplication
    function automatic logic [7:0] div5_12b(input logic [11:0] a);
        logic [25:0] p;
        p = {a, 13'b0} + {a, 12'b0} + {a, 9'b0} + {a, 8'b0} + {a, 5'b0} + {a, 4'b0} + {a, 2'b0};
        div5_12b = p[23:16];
    endfunction

    // Quotient and remainder extraction for ciphertext u indexing
    wire [7:0] q_u11 = div11_12b(rd_addr_q);
    wire [3:0] r_u11 = rd_addr_q - ({q_u11, 3'b0} + {q_u11, 1'b0} + q_u11);

    wire [7:0] q_u10 = div10_12b(rd_addr_q);
    wire [3:0] r_u10 = rd_addr_q - ({q_u10, 3'b0} + {q_u10, 1'b0});

    // Quotient and remainder extraction for ciphertext v indexing
    wire [7:0] q_v5  = div5_12b(enc_v_addr);
    wire [3:0] r_v5  = enc_v_addr - ({q_v5, 2'b0} + q_v5);
wire [7:0] q_v4  = enc_v_addr >> 2;
wire [3:0] r_v4  = enc_v_addr[1:0];

// Address translation from linear byte offset to (group, sub-byte)
always_comb begin
    if (rd_addr_q < enc_u_bytes) begin
        enc_read_group = (k_q == 4) ? q_u11 : q_u10;
        enc_read_sub   = (k_q == 4) ? r_u11 : r_u10;
    end else begin
        enc_read_group = {k_q, 5'd0} + ((k_q == 4) ? q_v5 : q_v4);
        enc_read_sub   = (k_q == 4) ? r_v5 : r_v4;
    end
end

logic [7:0]  enc_ct_byte;
logic [63:0] enc_secret_lane;

// Readout multiplexing logic for host access
always_comb begin
    case (enc_read_sub)
        0: enc_ct_byte = enc_read_word[7:0];
        1: enc_ct_byte = enc_read_word[15:8];
        2: enc_ct_byte = enc_read_word[23:16];
        3: enc_ct_byte = enc_read_word[31:24];
        4: enc_ct_byte = enc_read_word[39:32];
        5: enc_ct_byte = enc_read_word[47:40];
        6: enc_ct_byte = enc_read_word[55:48];
        7: enc_ct_byte = enc_read_word[63:56];
        8: enc_ct_byte = enc_read_word[71:64];
        9: enc_ct_byte = enc_read_word[79:72];
        default: enc_ct_byte = enc_read_word[87:80];
    endcase
    case (rd_addr_q[4:3])
        0: enc_secret_lane = shared_secret[63:0];
        1: enc_secret_lane = shared_secret[127:64];
        2: enc_secret_lane = shared_secret[191:128];
        default: enc_secret_lane = shared_secret[255:192];
    endcase
    enc_read_byte = 0;
    if (done && !enc_err_comb) begin
        if (rd_is_dk_q && rd_addr_q < 32) enc_read_byte = enc_secret_lane[rd_addr_q[2:0]*8 +: 8];
        if (mode_q == 1 && !rd_is_dk_q && rd_addr_q < enc_ct_bytes) enc_read_byte = enc_ct_byte;
    end
end

// ----------------------------------------------------------------------------
// Main Sequential Control and State Transition Process
// Controls full orchestration across all 18 FSM states (EC_0 through EC_17).
// ----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!rst_n || start_pulse) begin
        // Reset or initialize state based on operational mode
        enc_state_q <= enc_start ? (mode == 2 ? EC_DEC_WAIT : (mode == 1 && (k >= 2 && k <= 4)) ? EC_HASH_CMD : EC_FAIL) : EC_IDLE;
        enc_error_q <= start_pulse && (mode == 3 || (mode == 1 && (k < 2 || k > 4)));
        pk_error_q <= 0;
        enc_message_q <= enc_message;
        enc_message_shift_q <= enc_message;
        enc_secret_q <= 0;
        enc_rho_q <= 0;
        enc_h_q <= 0;
        enc_coins_q <= 0;
        enc_load_lane_q <= 0;
        enc_loading_t_q <= 1'b1;
        enc_load_done_q <= 1'b0;
        enc_is_last_lane_q <= 1'b0;
        enc_lane_last_block_q <= 1'b0;
        enc_pk_word_q <= 0;
        enc_raw_ready_q <= 0;
        enc_product_ready_q <= 0;
        enc_raw_words_q <= 0;
        enc_product_words_q <= 0;
        enc_raw_credit_q <= '0;
        enc_raw_has_word_q <= 1'b0;
        enc_product_credit_q <= '0;
        enc_product_has_word_q <= 1'b0;
        enc_feed_poly_lt_k_q <= 1'b1;
        enc_feed_poly_le_k_q <= 1'b1;
        enc_sample_beat_q <= 0;
        enc_ntt_state_q <= 0;
        enc_feed_poly_q <= 0;
        enc_feed_pair_q <= 0;
        enc_mul_col_q <= 0;
        enc_mul_col_is_last_q <= 1'b0;
        enc_mul_row_q <= 0;
        enc_mul_beat_q <= 0;
        enc_mul_beat_is_63_q <= 1'b0;
        enc_pk_group_q <= 6'd0;
        enc_is_matrix_q <= 1'b0;
        enc_is_v_q <= 1'b0;
        enc_mul_start_q <= 1'b1;
        enc_result_pair_q <= 0;
        enc_encode_poly_q <= 0;
        enc_encode_poly_is_k_q <= 1'b0;
        enc_ct_group_q <= 0;
        enc_ct_poly_q <= 0;
        enc_ct_poly_is_k_q <= 1'b0;
    end else if (enc_active) begin
        // Ingestion of public key lanes: deserializes t_hat and captures seed rho
        if (enc_load_fire) begin
            enc_load_lane_q <= enc_load_lane_q + 1'b1;
            if (enc_load_lane_q + 1'b1 == enc_t_lanes_q)
                enc_loading_t_q <= 1'b0; // Reached end of t_hat; remaining 4 lanes are seed rho
            if (enc_load_lane_q == enc_penultimate_lanes_q)
                enc_is_last_lane_q <= 1'b1;
            if (enc_is_last_lane_q)
                enc_load_done_q <= 1'b1;
            if (enc_load_lane_q + 1'b1 >= enc_full_block_lanes_q)
                enc_lane_last_block_q <= 1'b1;
            if (!enc_loading_t) enc_rho_q <= {ek_in_data,enc_rho_q[255:64]}; // Shift in 256-bit seed rho
            if (ek_in_last != enc_is_last_lane_q) begin
                enc_error_q <= 1; // Framing mismatch on external ek input
            end
        end

        // Public key decoding error trap
        if (enc_pk_write) begin
            enc_pk_word_q <= enc_pk_word_q + 1'b1;
            if (enc_pk_bad) pk_error_q <= 1;
        end

        // Sample beat progression for r, e_1, and e_2
        if (enc_r_write || enc_e1_write || enc_e2_write) begin
            enc_sample_beat_q <= enc_sample_beat_q + 1'b1;
            if (enc_r_write && sampler_out_last) enc_raw_ready_q[sampler_out_poly_index[1:0]] <= 1;
            if (enc_e2_write) enc_message_shift_q <= {4'd0,enc_message_shift_q[255:4]};
        end
        if (enc_r_write) enc_raw_words_q <= enc_raw_words_q + 1'b1;
        if (p3_valid && p3_is_last_col) enc_product_words_q <= enc_product_words_q + 1'b1;

        // Manage flow credit for raw r words
        case ({raw_inc, raw_dec})
            2'b10:   enc_raw_credit_q <= enc_raw_credit_q + 1'b1;
            2'b01:   enc_raw_credit_q <= enc_raw_credit_q - 1'b1;
            default: ;
        endcase
        enc_raw_has_word_q <= next_raw_has_word;

        // Manage flow credit for product words
        case ({prod_inc, prod_dec})
            2'b10:   enc_product_credit_q <= enc_product_credit_q + 1'b1;
            2'b01:   enc_product_credit_q <= enc_product_credit_q - 1'b1;
            default: ;
        endcase
        enc_product_has_word_q <= next_product_has_word;

        // NTT feeding sequencer
        if (enc_n_cmd_valid && ntt_cmd_ready) begin
            enc_ntt_state_q <= enc_ntt_state_q + 1'b1;
            enc_feed_poly_q <= 0;
            enc_feed_poly_lt_k_q <= 1'b1;
            enc_feed_poly_le_k_q <= 1'b1;
            enc_feed_pair_q <= 0;
        end else if (enc_n_valid && ntt_in_ready) begin
            enc_feed_pair_q <= enc_feed_pair_q + (enc_inverse ? 7'd2 : 7'd1);
            if (enc_n_last) begin
                enc_feed_poly_q <= enc_feed_poly_q + 1'b1;
                enc_feed_poly_lt_k_q <= (enc_feed_poly_q + 1'b1 < k_q);
                enc_feed_poly_le_k_q <= (enc_feed_poly_q + 1'b1 <= k_q);
            end
        end
        if (ntt_cmd_done && enc_ntt_state_q == 1) enc_ntt_state_q <= 2;

        // Multiplier beat and matrix coordinate counters
        if (!(enc_is_matrix_q || enc_is_v_q)) begin
            enc_mul_start_q <= 1'b1;
        end else if (enc_mul_valid && mul_s_ready) begin
            enc_mul_start_q <= enc_mul_beat_is_63_q;
        end
        if (enc_mul_valid && mul_s_ready) begin
            enc_mul_beat_q <= enc_mul_beat_q + 1'b1;
            enc_mul_beat_is_63_q <= (enc_mul_beat_q + 1'b1 == 6'd63);
            if (enc_mul_beat_q == 63) begin
                if (enc_mul_col_is_last_q) begin
                    enc_mul_col_q <= 0;
                    enc_mul_col_is_last_q <= 1'b0;
                    enc_mul_row_q <= enc_mul_row_q + 1'b1;
                    enc_pk_group_q <= 6'd0;
                end else begin
                    enc_mul_col_q <= enc_mul_col_q + 1'b1;
                    enc_mul_col_is_last_q <= (enc_mul_col_q + 1'b1 == k_q - 1'b1);
                    enc_pk_group_q <= {(enc_mul_col_q[1:0] + 1'b1), 4'd0};
                end
            end else if (enc_mul_beat_q[1:0] == 2'b11) begin
                enc_pk_group_q <= {enc_mul_col_q[1:0], enc_mul_beat_q[5:2] + 4'd1};
            end
        end

        // Product row readiness check
        if (p3_valid && p3_is_last_col && p3_beat == 63) enc_product_ready_q[p3_row] <= 1;

        // Post-processing and ciphertext emission counters
        if (!dec_compute && enc_inverse && ntt_out_valid && ntt_out_ready) begin
            enc_result_pair_q <= enc_result_pair_q + 1'b1;
        end
        if (!dec_compute && enc_compress_valid[0] && enc_encoder_ready && enc_compress_last[0]) begin
            enc_encode_poly_q <= enc_encode_poly_q + 1'b1;
            enc_encode_poly_is_k_q <= (enc_encode_poly_q + 1'b1 == k_q);
        end
        if (enc_emit) begin
            enc_ct_group_q <= enc_ct_group_q + 1'b1;
            if (enc_encoded_last) begin
                enc_ct_poly_q <= enc_ct_poly_q + 1'b1;
                enc_ct_poly_is_k_q <= (enc_ct_poly_q + 1'b1 == k_q);
            end
            if (enc_ct_last) enc_state_q <= EC_FINISH; // All ciphertext groups emitted
        end

        // --------------------------------------------------------------------
        // Encapsulation Main FSM State Transitions (EC_0 through EC_17)
        // --------------------------------------------------------------------
        case (enc_state_q)
            // EC_1: Command Keccak engine to hash public key ek -> H(pk)
            EC_HASH_CMD: begin
                if (k_q < 2 || k_q > 4) begin enc_error_q <= 1; enc_state_q <= EC_FAIL; end
                else if (sampler_cmd_ready) enc_state_q <= EC_LOAD;
            end

            // EC_2: Stream in public key ek = (t_hat || rho), compute H(pk)
            EC_LOAD: if (sampler_digest_valid) begin
                enc_h_q <= sampler_digest_out;
                enc_state_q <= enc_err_comb ? EC_FAIL : EC_G_CMD;
            end

            // EC_3: Command Keccak core for G(m || H(pk))
            EC_G_CMD: if (sampler_cmd_ready) enc_state_q <= EC_G_WAIT;

            // EC_4: Capture G hash digest -> shared secret K and randomness coins r
            EC_G_WAIT: if (sampler_digest_valid) begin
                enc_secret_q <= sampler_digest_out;
                enc_coins_q <= sampler_digest_out_sigma;
                enc_state_q <= EC_R_CMD;
            end

            // EC_5: Command PRF/CBD sampler for ephemeral error vector r
            EC_R_CMD: if (sampler_cmd_ready) enc_state_q <= EC_R;

            // EC_17: Wait for Decapsulation re-encryption kick (FO transform)
            EC_DEC_WAIT: if (dec_kick) begin
                enc_message_q <= dec_message;
                enc_message_shift_q <= dec_message;
                enc_h_q <= dec_h;
                enc_rho_q <= dec_rho;
                enc_product_credit_q <= 0;
                enc_product_has_word_q <= 0;
                enc_product_words_q <= 0;
                enc_product_ready_q <= 0;
                enc_state_q <= EC_G_CMD;
            end

            // EC_6: Sample vector r, launch NTT(r)
            EC_R: if (sampler_cmd_done) enc_state_q <= EC_E1_CMD;

            // EC_7: Command sampler for error vector e_1
            EC_E1_CMD: if (sampler_cmd_ready) enc_state_q <= EC_E1;

            // EC_8: Sample error vector e_1 (k polynomials)
            EC_E1: if (sampler_cmd_done) enc_state_q <= EC_E2_CMD;

            // EC_9: Command sampler for scalar error e_2
            EC_E2_CMD: if (sampler_cmd_ready) enc_state_q <= EC_E2;

            // EC_10: Sample e_2, add message modulation, store to enc_e2_ram
            EC_E2: if (sampler_cmd_done) enc_state_q <= EC_MATRIX_CMD;

            // EC_11: Command SHAKE128 XOF matrix A^T expansion from seed rho
            EC_MATRIX_CMD: if (sampler_cmd_ready) begin enc_state_q <= EC_MATRIX; enc_is_matrix_q <= 1'b1; end

            // EC_12: Parallel Matrix A^T * r_hat multiplication and accumulation
            EC_MATRIX: if (sampler_cmd_done) begin enc_state_q <= EC_V; enc_is_matrix_q <= 1'b0; enc_is_v_q <= 1'b1; enc_pk_group_q <= 6'd0; end

            // EC_13: Vector inner product v_hat = t_hat^T * r_hat in NTT domain
            EC_V: if (enc_mul_beat_is_63_q && enc_mul_col_is_last_q && mul_s_ready) begin enc_state_q <= EC_DRAIN; enc_is_v_q <= 1'b0; end

            default: begin end
        endcase

        // Asynchronous / synchronous error trap conditions forcing EC_FAIL
        if (dec_fail) begin enc_error_q <= 1; enc_state_q <= EC_FAIL; end
        if (ntt_cmd_error) begin enc_error_q <= 1; enc_state_q <= EC_FAIL; enc_is_matrix_q <= 1'b0; enc_is_v_q <= 1'b0; end
        if (enc_error_q) enc_state_q <= EC_FAIL;
    end
end
