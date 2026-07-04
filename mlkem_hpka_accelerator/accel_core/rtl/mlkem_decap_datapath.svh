//=============================================================================
// File: mlkem_decap_datapath.svh
// Description: ML-KEM Decapsulation (Decap) Datapath and Control Subsystem.
//              Included within `mlkem_keygen_top.sv`.
//
// Target Standard: FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Operation Mode:
//   - Mode 2: ML-KEM Decapsulation (Decap(dk, c) -> K)
//
// Security Levels Supported:
//   - ML-KEM-512  (k=2, d_u=10, d_v=4, eta1=3, eta2=2)
//   - ML-KEM-768  (k=3, d_u=10, d_v=4, eta1=2, eta2=2)
//   - ML-KEM-1024 (k=4, d_u=11, d_v=5, eta1=2, eta2=2)
//
// Theoretical Foundations & Algorithmic Workflow:
//   Compliant with FIPS 203 Section 6.2 (Algorithm 17: ML-KEM.Decaps_internal):
//   1. Secret Key (dk) Ingestion & Unpacking:
//      Standard decapsulation key layout:
//        dk = s_hat || t_hat || rho || H(ek) || z
//      Deserializes and checks coefficients via `poly_decode12_lane` into RAMs.
//   2. Ciphertext (c) Ingestion & Decompression:
//      Ciphertext layout: c = (u || v)
//      Unpacked via `poly_decode_group` and decompressed via `mlkem_poly_decompress`
//      to reconstruct vector u in R_q^k and scalar v in R_q.
//   3. Forward NTT on Ciphertext Vector u:
//      Computes u_hat = NTT(u) in NTT domain.
//   4. Inner Product & Subtraction (Decryption):
//      Computes candidate message polynomial:
//        w = v - INTT(s_hat^T * u_hat)
//   5. Message Bit Recovery:
//      Extracts 256-bit message m' via 1-bit compression:
//        m' = Compress_1(w)
//   6. Concurrent Keccak Hashing:
//      - Verifies H(ek) against SHA3-256(ek) stored in dk (integrity check).
//      - Computes implicit rejection pseudo-key K_reject = SHAKE256(z || c)
//        via dedicated packing/streaming logic into the Keccak core.
//   7. Fujisaki-Okamoto (FO) Re-Encryption:
//      Executes Encap(pk, m') to generate candidate ciphertext c' and candidate key K_true.
//   8. Constant-Time Ciphertext Verification:
//      Compares c' == c word-by-word across all 88-bit packed groups in constant time,
//      preventing side-channel timing leaks.
//   9. Implicit Rejection Key Selection:
//      If c' == c and H(ek) matches:
//        shared_secret = K_true
//      Else:
//        shared_secret = K_reject = SHAKE256(z || c)
//
// Decapsulation FSM States (dec_state_t):
//   --------------------------------------------------------------------------
//   Index | Symbolic Name | Function & Hardware Actions
//   --------------------------------------------------------------------------
//   DC_0  | DC_IDLE       | Standby state awaiting decapsulation start.
//   DC_1  | DC_FWD_CMD    | Issue forward NTT command for ciphertext vector u.
//   DC_2  | DC_FWD        | Stream unpacked u into NTT engine -> u_hat.
//   DC_3  | DC_INV_CMD    | Issue inverse NTT command for inner product s_hat^T * u_hat.
//   DC_4  | DC_INV        | Inverse NTT processing; stream into `field_sub` to compute
//         |               | w = v - INTT(s_hat^T * u_hat), compress to recover m'.
//   DC_5  | DC_REENC      | Message m' recovered; launch FO transform re-encryption
//         |               | (c' = Encap(pk, m')) and constant-time equality comparator.
//=============================================================================

// Decapsulation prefix and implicit rejection. Arithmetic and Keccak engines
// are shared with KeyGen/encapsulation. RAM validity is tracked by word counts.

// ----------------------------------------------------------------------------
// Decapsulation Finite State Machine (FSM) State Type Definition
// States DC_0 through DC_5 control the decryption and re-encryption sequence.
// ----------------------------------------------------------------------------
typedef enum logic [2:0] {
    DC_IDLE,    // DC_0: Idle / standby waiting for start_pulse in Mode 2
    DC_FWD_CMD, // DC_1: Command NTT core to execute forward NTT on vector u
    DC_FWD,     // DC_2: Feed decompressed u words to NTT core -> u_hat
    DC_INV_CMD, // DC_3: Command NTT core to execute inverse NTT on s_hat^T * u_hat
    DC_INV,     // DC_4: Stream INTT result, subtract from v, recover message m'
    DC_REENC    // DC_5: Launch re-encryption c'=Encap(pk, m') and constant-time compare
} dec_state_t;
dec_state_t dec_state_q;

// Decapsulation active computation status flag
logic dec_compute_q;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dec_compute_q <= 1'b0;
    end else if (start_pulse) begin
        dec_compute_q <= (mode == 2); // Asserted only for ML-KEM Decapsulation (Mode 2)
    end else if (enc_complete || enc_abort || dec_kick) begin
        dec_compute_q <= 1'b0;
    end
end
assign dec_compute = dec_compute_q;

// Error, status, and completion tracking flags
logic dec_error_q, dec_sk_bad_q, dec_pk_bad_q, dec_message_done_q, dec_hash_checked_q, dec_j_done_q, dec_h_done_q;

// Security registers: recovered message, hash digest, seed rho, reject seed z, and rejection key
logic [255:0] dec_message_q, dec_h_q, dec_rho_q, dec_z_q, dec_reject_q;
assign dec_message = dec_message_q;
assign dec_h = dec_h_q;
assign dec_rho = dec_rho_q;
assign dec_reject = dec_reject_q;
assign dec_fail = dec_compute && (dec_error_q || dec_sk_bad_q || dec_pk_bad_q || k_invalid_q);

// Handshake kick to trigger FO re-encryption in encapsulation datapath
assign dec_kick = dec_compute && dec_message_done_q && dec_j_done_q && dec_hash_checked_q && !dec_fail;

// ----------------------------------------------------------------------------
// Decapsulation Key (dk) Deserialization & Storage Subsystem
// FIPS 203 format: dk = s_hat || t_hat || rho || H(ek) || z
// Total lengths:
//   - ML-KEM-512:  96 lanes s_hat, 96 lanes t_hat, 4 lanes rho, 4 lanes H, 4 lanes z (204 total)
//   - ML-KEM-768:  144 lanes s_hat, 144 lanes t_hat, 4 lanes rho, 4 lanes H, 4 lanes z (300 total)
//   - ML-KEM-1024: 192 lanes s_hat, 192 lanes t_hat, 4 lanes rho, 4 lanes H, 4 lanes z (396 total)
// ----------------------------------------------------------------------------
// Standard dk = s_hat || t_hat || rho || H(ek) || z.
logic [8:0] dec_dk_lane_q, dec_sk_words_q;
logic       dec_loading_s_q, dec_loading_pk_q, dec_loading_rho_q, dec_loading_h_q, dec_loading_z_q;
logic       dec_loading_ek_q, dec_dk_done_q;
logic       dec_h_last_block_q;
logic [8:0] dec_s_end_q, dec_pk_end_q, dec_rho_end_q, dec_h_end_q, dec_dk_lanes_q;
logic [8:0] dec_h_last_block_start_q;
logic [7:0] dec_j_full_q, dec_j_total_q;
logic [4:0] dec_j_rem_lanes_q;
logic       dec_j_last_block_q, dec_j_lanes_done_q;

wire dec_sk_ready, dec_sk_bad;
wire dec_dk_fire = dk_in_valid && dk_in_ready;
assign dk_in_ready = dec_compute && !k_invalid_q && !dec_dk_done_q &&
    (dec_loading_s_q ? dec_sk_ready : dec_loading_ek_q ? sampler_in_lane_ready && (!dec_loading_pk_q || enc_decoder_ready) : 1'b1);
assign dec_pk_write = dec_dk_fire && dec_loading_pk_q;
assign dec_sk_addr = dec_sk_words_q[7:0];

// 12-bit secret key decoder: unpacks 64-bit lanes to 12-bit polynomial coefficients and checks s_i < 3329
poly_decode12_lane dec_sk_decoder (
    .clk(clk), .rst_n(rst_n), .clear(start_pulse || enc_abort),
    .in_valid(dec_dk_fire && dec_loading_s_q), .in_ready(dec_sk_ready), .in_data(dk_in_data),
    .out_valid(dec_sk_write), .out_ready(1'b1), .out_data(dec_sk_data), .out_bad(dec_sk_bad)
);

// ----------------------------------------------------------------------------
// Ciphertext Ingestion, Decoding, and Polynomial Decompression Pipeline
// Receives packed ciphertext c = (u || v) and extracts coefficients.
// ----------------------------------------------------------------------------
// Retained ciphertext groups feed decoding, J(z||c), and full comparison.
wire dec_ct_v = dec_ct_groups_q >= {k_q,5'd0};
wire [3:0] dec_ct_d = dec_ct_v ? enc_dv_q : enc_du_q;
wire dec_ct_last = dec_ct_groups_q + 1'b1 == ({k_q,5'd0}+8'd32);
wire dec_decode_ready, dec_pair_valid, dec_pair_last;
wire [21:0] dec_pair;
logic [3:0] dec_pair_d_q;
assign ct_in_ready = dec_compute && !k_invalid_q && dec_ct_groups_q < ({k_q,5'd0}+8'd32) && dec_decode_ready;

// Group decoder: unpacks serialized bitstreams according to bitwidth d_u or d_v
poly_decode_group dec_ct_decoder (
    .clk(clk), .rst_n(rst_n), .clear(start_pulse || enc_abort), .cfg_d(dec_ct_d),
    .in_valid(ct_in_valid && ct_in_ready), .in_ready(dec_decode_ready), .in_data(ct_in_data),
    .in_last(dec_ct_groups_q[4:0] == 31), .out_valid(dec_pair_valid), .out_ready(1'b1),
    .out_data(dec_pair), .out_last(dec_pair_last)
);

// Dual hardware decompressors computing round((y * q) / 2^d)
wire [1:0] dec_decomp_valid, dec_decomp_last;
wire [11:0] dec_decomp_data [0:1];
for (genvar dl=0;dl<2;dl++) begin: DEC_DECOMPRESS
    mlkem_poly_decompress decompress (
        .clk(clk), .rst_n(enc_codec_rst_n), .s_axis_tvalid(dec_pair_valid), .s_axis_tready(),
        .s_axis_tdata(dec_pair[dl*11 +:11]), .s_axis_td(dec_pair_d_q), .s_axis_tlast(dec_pair_last),
        .m_axis_tvalid(dec_decomp_valid[dl]), .m_axis_tready(1'b1),
        .m_axis_tdata(dec_decomp_data[dl]), .m_axis_tlast(dec_decomp_last[dl])
    );
end

// Packing 2 decompressed coefficients into 48-bit memory words for staging RAMs
logic dec_decomp_half_q;
logic [23:0] dec_decomp_lo_q;
logic [8:0] dec_decomp_words_q;
logic dec_is_u_words_q;
logic [8:0] dec_u_end_words_q;
assign dec_u_write = &dec_decomp_valid && dec_decomp_half_q && dec_is_u_words_q;
assign dec_v_write = &dec_decomp_valid && dec_decomp_half_q && !dec_is_u_words_q;
assign dec_u_addr = dec_decomp_words_q[7:0];
assign dec_v_addr = dec_decomp_words_q[5:0];
assign dec_u_data = {dec_decomp_data[1],dec_decomp_data[0],dec_decomp_lo_q};
assign dec_v_data = dec_u_data;

// ----------------------------------------------------------------------------
// Arithmetic Datapath Sequencing: NTT(u), Vector Dot Product, and Decryption
// Computes w = v - INTT(s_hat^T * u_hat)
// Flow control uses credit counters to decouple memory writes from NTT ingestion.
// ----------------------------------------------------------------------------
// u uses inverse staging RAM, NTT(u) ram_s, and s_hat ram_e. Product overwrites
// staging only after all raw u words have already been consumed.
logic [8:0] dec_fwd_credit_q;
logic       dec_has_fwd_credit_q;
logic       dec_mul_start_q;
logic [2:0] dec_feed_poly_q;
assign dec_n_cmd = dec_compute && (dec_state_q == DC_FWD_CMD || dec_state_q == DC_INV_CMD);
assign dec_n_inverse = dec_state_q == DC_INV_CMD || dec_state_q == DC_INV;
assign dec_n_polys = dec_n_inverse ? 5'd1 : {2'd0,k_q};
assign dec_n_poly = {1'b0,dec_feed_poly_q};
assign dec_n_last = dec_n_inverse ? dec_feed_pair_q == 126 : dec_feed_pair_q == 127;
assign dec_feed_word = enc_product_word;
assign dec_n_data = dec_feed_pair_q[0] ? dec_feed_word[47:24] : dec_feed_word[23:0];
logic [8:0] dec_u_credit_q;
logic       dec_u_has_word_q;
wire dec_u_inc = dec_u_write;
wire dec_u_dec = dec_n_valid && ntt_in_ready && (dec_state_q == DC_FWD) && dec_feed_pair_q[0];

logic next_u_has_word;
always_comb begin
    case ({dec_u_inc, dec_u_dec})
        2'b10:   next_u_has_word = 1'b1;
        2'b01:   next_u_has_word = |dec_u_credit_q[8:1];
        default: next_u_has_word = dec_u_has_word_q;
    endcase
end

// Flow credit tracking for inner product words feeding inverse NTT
logic [6:0] dec_prod_credit_q;
logic       dec_prod_has_word_q;
wire dec_prod_inc = p3_valid && p3_is_last_col;
wire dec_prod_dec = dec_n_valid && ntt_in_ready && (dec_state_q == DC_INV);

logic next_prod_has_word;
always_comb begin
    case ({dec_prod_inc, dec_prod_dec})
        2'b10:   next_prod_has_word = 1'b1;
        2'b01:   next_prod_has_word = |dec_prod_credit_q[6:1];
        default: next_prod_has_word = dec_prod_has_word_q;
    endcase
end

// Credit tracking for forward NTT results stored in ram_s feeding multiplier
logic next_has_fwd_credit;
always_comb begin
    case ({dec_ram_s_we, (dec_mul_valid && mul_s_ready)})
        2'b10:   next_has_fwd_credit = 1'b1;
        2'b01:   next_has_fwd_credit = |dec_fwd_credit_q[8:1];
        default: next_has_fwd_credit = dec_has_fwd_credit_q;
    endcase
end

logic dec_feed_poly_lt_k_q;
logic dec_inv_poly_done_q;

assign dec_n_valid = dec_compute &&
    ((dec_state_q == DC_FWD && dec_feed_poly_lt_k_q && dec_u_has_word_q) ||
     (dec_state_q == DC_INV && !dec_inv_poly_done_q && dec_prod_has_word_q));
assign dec_mul_a = dec_ram_e_rdata;
assign dec_mul_b = s_word_read;
assign dec_mul_valid = dec_compute && dec_dk_done_q && dec_has_fwd_credit_q;
assign dec_mul_start = dec_mul_start_q;
assign dec_mul_reset = !rst_n || start_pulse || enc_abort;
wire [47:0] dec_v_word = enc_e2_read_word;
assign dec_v_pair = dec_result_pair_q[0] ? dec_v_word[47:24] : dec_v_word[23:0];

// ----------------------------------------------------------------------------
// Ciphertext Lane Packing & Stream Generation for SHAKE256(z || c)
// Packs variable-width ciphertext groups into standard 64-bit Keccak lanes.
// Constant shift steps (8 or 16 bits) avoid wide dynamic shifters for high Fmax.
// ----------------------------------------------------------------------------
// Convert groups to hash lanes concurrently with key loading. Each step shifts
// by a constant 8 or 16 bits. No wide dynamic shift or variable part select.
(* ram_style = "distributed" *) logic [63:0] dec_ct_lanes [0:195];
logic [7:0] dec_lane_words_q;
(* max_fanout = 16 *) logic [7:0] dec_ct_rd_ptr_q;
logic [7:0] dec_ct_avail_q;
logic       dec_ct_has_data_q;
logic       dec_j_z_phase_q;
logic [87:0] dec_pack_shift_q;
logic [3:0] dec_pack_left_q;
logic [63:0] dec_pack_lane_q;
logic [2:0] dec_pack_bytes_q;
wire [3:0] dec_pack_group_bytes = dec_pack_group_q < {k_q,5'd0} ? enc_du_q : enc_dv_q;
wire dec_pack_one = dec_pack_left_q == 1 || dec_pack_bytes_q == 7;
wire dec_pack_step = dec_compute && dec_pack_left_q != 0;
wire dec_lane_commit = dec_pack_step && (dec_pack_bytes_q == 7 || (!dec_pack_one && dec_pack_bytes_q == 6));
wire [63:0] dec_lane_next = dec_pack_one ? {dec_pack_shift_q[7:0],dec_pack_lane_q[63:8]} :
                                                          {dec_pack_shift_q[15:0],dec_pack_lane_q[63:16]};
logic        dec_commit_q;
logic [7:0]  dec_commit_addr_q;
logic [63:0] dec_commit_data_q;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dec_commit_q <= 1'b0;
    end else if (start_pulse || enc_abort) begin
        dec_commit_q <= 1'b0;
    end else begin
        dec_commit_q <= dec_lane_commit;
    end
end

always_ff @(posedge clk) begin
    dec_commit_addr_q <= dec_lane_words_q;
    dec_commit_data_q <= dec_lane_next;
    if (dec_commit_q) dec_ct_lanes[dec_commit_addr_q] <= dec_commit_data_q;
end

// ----------------------------------------------------------------------------
// Keccak Hashing Sub-FSM: H(pk) Verification & J(z || c) Implicit Rejection
// DH_H: Computes SHA3-256(ek) to verify against H(ek) from dk
// DH_J: Computes SHAKE256(z || c) to generate 256-bit rejection key K_reject
// ----------------------------------------------------------------------------
typedef enum logic [2:0] {DH_H_CMD,DH_H,DH_J_CMD,DH_J,DH_DONE} dec_hash_state_t;
dec_hash_state_t dec_hash_state_q;
logic dec_is_dh_h_q, dec_is_dh_j_q;
logic [7:0] dec_j_lane_q;
logic [255:0] dec_z_shift_q;
wire dec_ct_push = dec_commit_q;
wire dec_lane_h_valid = dec_is_dh_h_q && dk_in_valid && dec_loading_ek_q && (!dec_loading_pk_q || enc_decoder_ready);
wire dec_lane_j_valid = dec_is_dh_j_q && !dec_j_lanes_done_q && (dec_j_z_phase_q || dec_ct_has_data_q);
wire dec_ct_pop  = dec_lane_j_valid && sampler_in_lane_ready && !dec_j_z_phase_q;
assign dec_rem_lanes = dec_is_dh_h_q ? sampler_in_rem_lanes : dec_j_rem_lanes_q;
assign dec_s_cmd = dec_compute && (dec_hash_state_q == DH_H_CMD || dec_hash_state_q == DH_J_CMD);
assign dec_s_mode = dec_hash_state_q == DH_H_CMD ? 3'd0 : 3'd4; // Mode 0: SHA3-256; Mode 4: SHAKE256
assign dec_lane_valid = dec_compute && (dec_lane_h_valid || dec_lane_j_valid);

assign dec_lane = dec_is_dh_h_q ? dk_in_data :
                 dec_j_z_phase_q ? dec_z_shift_q[63:0] : dec_ct_lanes[dec_ct_rd_ptr_q];
assign dec_lane_last = dec_is_dh_h_q ? dec_h_last_block_q : dec_j_last_block_q;

// ----------------------------------------------------------------------------
// Constant-Time Ciphertext Comparison Pipeline
// During FO re-encryption (c' = Encap(pk, m')), compares re-encrypted c'
// against original ciphertext c stored in enc_ct_ram.
// Comparison runs in constant time to eliminate side-channel timing vulnerabilities.
// ----------------------------------------------------------------------------
logic dec_mismatch_q;
assign dec_mismatch = dec_mismatch_q;
assign dec_compare_word = enc_ct_ram[dec_compute ? dec_pack_group_q : enc_ct_group_q];

logic        dec_cmp_valid_q;
logic [87:0] dec_cmp_ct_q, dec_cmp_word_q;
always_ff @(posedge clk) begin
    if (!rst_n || start_pulse) begin
        dec_cmp_valid_q <= 1'b0;
        dec_cmp_ct_q    <= 88'd0;
        dec_cmp_word_q  <= 88'd0;
    end else begin
        dec_cmp_valid_q <= (mode_q == 2 && enc_emit);
        dec_cmp_ct_q    <= enc_ct_data;
        dec_cmp_word_q  <= dec_compare_word;
    end
end

wire dec_group_diff = (dec_cmp_ct_q != dec_cmp_word_q);

// Constant-time public key hash verification logic
logic dec_h_mismatch_q;
wire [63:0] dec_h_diff_u4;
for (genvar qi = 0; qi < 64; qi++) begin : GEN_H_DIFF
    assign dec_h_diff_u4[qi] = |(sampler_digest_out[qi*4 +: 4] ^ dec_h_q[qi*4 +: 4]);
end
wire [10:0] dec_h_diff_l2;
for (genvar li = 0; li < 10; li++) begin : GEN_H_L2
    assign dec_h_diff_l2[li] = |dec_h_diff_u4[li*6 +: 6];
end
assign dec_h_diff_l2[10] = |dec_h_diff_u4[63:60];
wire dec_h_mismatch = |dec_h_diff_l2;

// ----------------------------------------------------------------------------
// Decapsulation Main Sequential Process
// Manages key parsing, FSM state sequencing (DC_0 - DC_5), flow credit updates,
// message bit aggregation, hash state transitions, and implicit rejection.
// ----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!rst_n || start_pulse) begin
        dec_state_q <= start_pulse && mode == 2 ? DC_FWD_CMD : DC_IDLE;
        dec_error_q <= 0; dec_sk_bad_q <= 0; dec_pk_bad_q <= 0; dec_message_done_q <= 0; dec_hash_checked_q <= 0; dec_j_done_q <= 0; dec_h_done_q <= 0;
        dec_message_q <= 0; dec_h_q <= 0; dec_rho_q <= 0; dec_z_q <= 0;
        dec_reject_q <= 0; dec_mismatch_q <= 0; dec_h_mismatch_q <= 0;
        dec_dk_lane_q <= 0; dec_sk_words_q <= 0; dec_ct_groups_q <= 0;
        dec_pair_d_q <= k == 4 ? 11 : 10;
        dec_decomp_half_q <= 0; dec_decomp_lo_q <= 0; dec_decomp_words_q <= 0;
        dec_is_u_words_q <= 1'b1;
        dec_feed_pair_q <= 0; dec_feed_poly_q <= 0;
        dec_fwd_credit_q <= 0; dec_has_fwd_credit_q <= 0;
        dec_mul_word_q <= 0; dec_mul_start_q <= 1'b1; dec_result_pair_q <= 0;
        dec_u_credit_q <= 0; dec_u_has_word_q <= 0;
        dec_prod_credit_q <= 0; dec_prod_has_word_q <= 0;
        dec_feed_poly_lt_k_q <= 0; dec_inv_poly_done_q <= 0;
        dec_pack_group_q <= 0; dec_pack_left_q <= 0; dec_pack_shift_q <= 0;
        dec_pack_lane_q <= 0; dec_pack_bytes_q <= 0; dec_lane_words_q <= 0;
        dec_hash_state_q <= DH_H_CMD; dec_is_dh_h_q <= 1'b0; dec_is_dh_j_q <= 1'b0;
        dec_j_lane_q <= 0; dec_ct_rd_ptr_q <= 0; dec_z_shift_q <= 0;
        dec_loading_s_q          <= 1'b1;
        dec_loading_pk_q         <= 1'b0;
        dec_loading_rho_q        <= 1'b0;
        dec_loading_h_q          <= 1'b0;
        dec_loading_z_q          <= 1'b0;
        dec_loading_ek_q         <= 1'b0;
        dec_dk_done_q            <= 1'b0;
        dec_h_last_block_q       <= 1'b0;
        dec_j_last_block_q       <= 1'b0;
        dec_j_lanes_done_q       <= 1'b0;
        dec_j_done_q             <= 1'b0;
        dec_ct_avail_q           <= 8'd0;
        dec_ct_has_data_q        <= 1'b0;
        dec_j_z_phase_q          <= 1'b1;

        // Configure lane boundaries according to parameter k
        case (k)
            3'd2: begin // ML-KEM-512
                dec_s_end_q              <= 9'd96;
                dec_pk_end_q             <= 9'd192;
                dec_rho_end_q            <= 9'd196;
                dec_h_end_q              <= 9'd200;
                dec_dk_lanes_q           <= 9'd204;
                dec_h_last_block_start_q <= 9'd181;
                dec_j_full_q             <= 8'd85;
                dec_j_total_q            <= 8'd100;
                dec_j_rem_lanes_q        <= 5'd15;
                dec_u_end_words_q        <= 9'd128;
            end
            3'd3: begin // ML-KEM-768
                dec_s_end_q              <= 9'd144;
                dec_pk_end_q             <= 9'd288;
                dec_rho_end_q            <= 9'd292;
                dec_h_end_q              <= 9'd296;
                dec_dk_lanes_q           <= 9'd300;
                dec_h_last_block_start_q <= 9'd280;
                dec_j_full_q             <= 8'd136;
                dec_j_total_q            <= 8'd140;
                dec_j_rem_lanes_q        <= 5'd4;
                dec_u_end_words_q        <= 9'd192;
            end
            default: begin // ML-KEM-1024
                dec_s_end_q              <= 9'd192;
                dec_pk_end_q             <= 9'd384;
                dec_rho_end_q            <= 9'd388;
                dec_h_end_q              <= 9'd392;
                dec_dk_lanes_q           <= 9'd396;
                dec_h_last_block_start_q <= 9'd379;
                dec_j_full_q             <= 8'd187;
                dec_j_total_q            <= 8'd200;
                dec_j_rem_lanes_q        <= 5'd13;
                dec_u_end_words_q        <= 9'd256;
            end
        endcase
    end else begin
        // Accumulate ciphertext comparison mismatches in constant time
        if (dec_cmp_valid_q) dec_mismatch_q <= dec_mismatch_q || dec_group_diff;

        if (dec_compute) begin
            // Parse incoming decapsulation key dk
            if (dec_dk_fire) begin
                dec_dk_lane_q <= dec_dk_lane_q + 1'b1;
                if (dk_in_last != (dec_dk_lane_q + 1'b1 == dec_dk_lanes_q)) dec_error_q <= 1;
                if (dec_loading_rho_q) dec_rho_q <= {dk_in_data,dec_rho_q[255:64]};
                if (dec_loading_h_q)   dec_h_q   <= {dk_in_data,dec_h_q[255:64]};
                if (dec_loading_z_q)   dec_z_q   <= {dk_in_data,dec_z_q[255:64]};

                if (dec_dk_lane_q + 1'b1 == dec_s_end_q) begin
                    dec_loading_s_q   <= 1'b0;
                    dec_loading_pk_q  <= 1'b1;
                    dec_loading_ek_q  <= 1'b1;
                end
                if (dec_dk_lane_q + 1'b1 == dec_pk_end_q) begin
                    dec_loading_pk_q  <= 1'b0;
                    dec_loading_rho_q <= 1'b1;
                end
                if (dec_dk_lane_q + 1'b1 == dec_rho_end_q) begin
                    dec_loading_rho_q <= 1'b0;
                    dec_loading_ek_q  <= 1'b0;
                    dec_loading_h_q   <= 1'b1;
                end
                if (dec_dk_lane_q + 1'b1 == dec_h_end_q) begin
                    dec_loading_h_q   <= 1'b0;
                    dec_loading_z_q   <= 1'b1;
                end
                if (dec_dk_lane_q + 1'b1 == dec_dk_lanes_q) begin
                    dec_loading_z_q   <= 1'b0;
                    dec_dk_done_q     <= 1'b1;
                end
                if (dec_dk_lane_q + 1'b1 == dec_h_last_block_start_q) begin
                    dec_h_last_block_q <= 1'b1;
                end
            end

            // Secret key and public key decoding validation
            if (dec_sk_write) begin
                dec_sk_words_q <= dec_sk_words_q + 1'b1;
                if (dec_sk_bad) dec_sk_bad_q <= 1;
            end
            if (enc_pk_write && enc_pk_bad) dec_pk_bad_q <= 1;

            // Ciphertext group ingestion
            if (ct_in_valid && ct_in_ready) begin
                dec_ct_groups_q <= dec_ct_groups_q + 1'b1;
                dec_pair_d_q <= dec_ct_d;
                if (ct_in_bytes != dec_ct_d || ct_in_last != dec_ct_last) dec_error_q <= 1;
            end

            // Decompressed coefficient pairing and write sequencing
            if (&dec_decomp_valid) begin
                dec_decomp_half_q <= !dec_decomp_half_q;
                dec_decomp_lo_q <= {dec_decomp_data[1],dec_decomp_data[0]};
                if (dec_decomp_half_q) begin
                    dec_decomp_words_q <= dec_decomp_words_q + 1'b1;
                    if (dec_decomp_words_q + 1'b1 == dec_u_end_words_q) begin
                        dec_is_u_words_q <= 1'b0;
                    end
                end
            end

            // Flow credit update for u words
            case ({dec_u_inc, dec_u_dec})
                2'b10:   dec_u_credit_q <= dec_u_credit_q + 1'b1;
                2'b01:   dec_u_credit_q <= dec_u_credit_q - 1'b1;
                default: dec_u_credit_q <= dec_u_credit_q;
            endcase
            dec_u_has_word_q <= next_u_has_word;

            // Flow credit update for inner product words
            case ({dec_prod_inc, dec_prod_dec})
                2'b10:   dec_prod_credit_q <= dec_prod_credit_q + 1'b1;
                2'b01:   dec_prod_credit_q <= dec_prod_credit_q - 1'b1;
                default: dec_prod_credit_q <= dec_prod_credit_q;
            endcase
            dec_prod_has_word_q <= next_prod_has_word;

            // NTT feeding sequencer for decapsulation
            if (dec_n_cmd && ntt_cmd_ready) begin
                dec_state_q <= dec_n_inverse ? DC_INV : DC_FWD;
                dec_feed_pair_q <= 0; dec_feed_poly_q <= 0;
                dec_feed_poly_lt_k_q <= 1'b1;
                dec_inv_poly_done_q <= 1'b0;
            end else if (dec_n_valid && ntt_in_ready) begin
                dec_feed_pair_q <= dec_feed_pair_q + (dec_n_inverse ? 7'd2 : 7'd1);
                if (dec_n_last) begin
                    dec_feed_poly_q <= dec_feed_poly_q + 1'b1;
                    dec_feed_poly_lt_k_q <= (dec_feed_poly_q + 1'b1 < k_q);
                    dec_inv_poly_done_q <= 1'b1;
                end
            end
            if (dec_state_q == DC_FWD && ntt_cmd_done) dec_state_q <= DC_INV_CMD;

            // Forward credit management for multiplier dot product
            case ({dec_ram_s_we, (dec_mul_valid && mul_s_ready)})
                2'b10: dec_fwd_credit_q <= dec_fwd_credit_q + 1'b1;
                2'b01: dec_fwd_credit_q <= dec_fwd_credit_q - 1'b1;
                default: dec_fwd_credit_q <= dec_fwd_credit_q;
            endcase
            dec_has_fwd_credit_q <= next_has_fwd_credit;

            if (dec_mul_valid && mul_s_ready) begin
                dec_mul_word_q <= dec_mul_word_q + 1'b1;
                dec_mul_start_q <= (dec_mul_word_q[5:0] == 6'd63);
            end
            if (dec_n_inverse && ntt_out_valid && ntt_out_ready) dec_result_pair_q <= dec_result_pair_q + 1'b1;

            // Reconstruct 256-bit message m' from 1-bit compressed ring elements (Compress_1(w))
            if (&enc_compress_valid) begin
                dec_message_q <= {enc_compressed[1][0],enc_compressed[0][0],dec_message_q[255:2]};
                if (enc_compress_last[0]) dec_message_done_q <= 1;
            end
            if (ntt_cmd_error) dec_error_q <= 1;
            if (dec_kick) dec_state_q <= DC_REENC;

            // Ciphertext byte packing for J(z || c)
            if (dec_pack_left_q == 0 && dec_pack_group_q < dec_ct_groups_q) begin
                dec_pack_shift_q <= dec_compare_word;
                dec_pack_left_q <= dec_pack_group_bytes;
                dec_pack_group_q <= dec_pack_group_q + 1'b1;
            end else if (dec_pack_step) begin
                dec_pack_shift_q <= dec_pack_one ? {8'd0,dec_pack_shift_q[87:8]} : {16'd0,dec_pack_shift_q[87:16]};
                dec_pack_left_q <= dec_pack_left_q - (dec_pack_one ? 4'd1 : 4'd2);
                dec_pack_lane_q <= dec_lane_next;
                dec_pack_bytes_q <= dec_pack_bytes_q + (dec_pack_one ? 3'd1 : 3'd2);
                if (dec_lane_commit) dec_lane_words_q <= dec_lane_words_q + 1'b1;
            end
            if (dec_ct_push && !dec_ct_pop) begin
                dec_ct_avail_q    <= dec_ct_avail_q + 8'd1;
                dec_ct_has_data_q <= 1'b1;
            end else if (!dec_ct_push && dec_ct_pop) begin
                dec_ct_avail_q    <= dec_ct_avail_q - 8'd1;
                dec_ct_has_data_q <= (dec_ct_avail_q > 8'd1);
            end

            // ----------------------------------------------------------------
            // Hash Sub-FSM State Transitions (H(pk) and J(z || c))
            // ----------------------------------------------------------------
            case (dec_hash_state_q)
                // Issue SHA3-256 command for public key validation
                DH_H_CMD: if (sampler_cmd_ready) begin
                    dec_hash_state_q <= DH_H;
                    dec_is_dh_h_q    <= 1'b1;
                end
                // Process H(pk) digest and check equality
                DH_H: begin
                    if (sampler_digest_valid) begin
                        dec_h_mismatch_q <= dec_h_mismatch;
                        dec_h_done_q     <= 1'b1;
                    end
                    if (dec_dk_done_q && dec_h_done_q) begin
                        dec_hash_checked_q <= 1;
                        if (dec_h_mismatch_q) dec_error_q <= 1;
                        dec_z_shift_q <= dec_z_q;
                        dec_hash_state_q <= DH_J_CMD;
                        dec_is_dh_h_q    <= 1'b0;
                    end
                end
                // Issue SHAKE256 command for rejection key K_reject = SHAKE256(z || c)
                DH_J_CMD: if (sampler_cmd_ready) begin
                    dec_hash_state_q <= DH_J;
                    dec_is_dh_j_q    <= 1'b1;
                end
                // Stream z seed followed by serialized ciphertext lanes into SHAKE256
                DH_J: begin
                    if (dec_lane_j_valid && sampler_in_lane_ready) begin
                        dec_j_lane_q <= dec_j_lane_q + 1'b1;
                        if (dec_j_z_phase_q) dec_z_shift_q <= {64'd0,dec_z_shift_q[255:64]};
                        else dec_ct_rd_ptr_q <= dec_ct_rd_ptr_q + 1'b1;

                        if (dec_j_lane_q == 8'd3) begin
                            dec_j_z_phase_q <= 1'b0; // 4 lanes of z complete; start ciphertext
                        end
                        if (dec_j_lane_q + 1'b1 == dec_j_full_q) begin
                            dec_j_last_block_q <= 1'b1;
                        end
                        if (dec_j_lane_q + 1'b1 == dec_j_total_q) begin
                            dec_j_lanes_done_q <= 1'b1;
                        end
                    end
                    // Capture 256-bit rejection pseudo-key from SHAKE256 digest
                    if (sampler_digest_valid) begin
                        dec_reject_q <= sampler_digest_out; dec_j_done_q <= 1; dec_hash_state_q <= DH_DONE;
                        dec_is_dh_j_q <= 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end
end
