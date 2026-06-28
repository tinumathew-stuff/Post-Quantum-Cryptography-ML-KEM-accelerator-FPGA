`timescale 1ns/1ps

//==================================================================================================
// Module Name: sha3_256_core
// Project:     ML-KEM High-Performance Kyber Accelerator (HPKA)
// Standards:   NIST FIPS 202 (SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions)
//              NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism / ML-KEM)
//
// Description:
//   Dedicated, high-throughput hardware implementation of the NIST SHA3-256 cryptographic hash
//   function, optimized specifically for Module-Lattice Key-Encapsulation Mechanism (ML-KEM).
//
// Cryptographic Role in ML-KEM (Kyber):
//   In ML-KEM (FIPS 203), SHA3-256 serves as the primary hash function H() across all parameter sets
//   (ML-KEM-512, ML-KEM-768, ML-KEM-1024):
//     1. Key Generation (ML-KEM.KeyGen):
//        Computes public key digest H(ek) = SHA3-256(ek). This 32-byte hash is embedded directly
//        into the decapsulation key dk = (dk_pke || ek || H(ek) || z) to bind the secret key to ek.
//     2. Encapsulation (ML-KEM.Encaps):
//        Hashes the encapsulation key H(ek) during the derivation of shared secret and coin seeds:
//        (K, r) = G(m || H(ek)).
//     3. Decapsulation (ML-KEM.Decaps):
//        Validates ciphertext integrity and public key binding during the Fujisaki-Okamoto (FO)
//        transform re-encryption check.
//
//   Instantiating this dedicated SHA3-256 core in `accel_core` offloads the public key hashing
//   from the unified sampler/Keccak engine, allowing parallel execution of matrix sampling,
//   number theoretic transforms (NTT), and hash digest generation without pipeline stalls.
//
// Sponge Architecture Parameters (FIPS 202 Section 6.1):
//   - State Width (b):       1600 bits (25 x 64-bit lanes, A[0..24])
//   - Capacity (c):          512 bits (8 lanes, A[17..24]), providing 128-bit classical collision
//                            and preimage resistance against quantum/classical attacks.
//   - Bit Rate (r):          1088 bits = 17 lanes (A[0..16]).
//   - Digest Length (d):     256 bits = 4 lanes (A[0..3]).
//   - Padding Rule:          pad10*1 with domain separator byte 0x06:
//                            P = M || 0x06 || 0x00...00 || 0x80.
//
// ML-KEM Encapsulation Key (ek) Block Dimensions:
//   The encapsulation key consists of serialized polynomial vector t (k * 384 bytes) and seed rho
//   (32 bytes). Every word is 64-bit (8-byte) lane aligned:
//     - ML-KEM-512  (k=2): ek = 800 bytes = 100 lanes -> 5 full blocks (5*17=85) + 15 rem lanes (k=2).
//     - ML-KEM-768  (k=3): ek = 1184 bytes = 148 lanes -> 8 full blocks (8*17=136) + 12 rem lanes (k=3).
//     - ML-KEM-1024 (k=4): ek = 1568 bytes = 196 lanes -> 11 full blocks (11*17=187) + 9 rem lanes (k=4).
//   The `in_rem_lanes` input dynamically defines the boundary for the last block padding injection.
//
// Padding Construction in Hardware:
//   - When in_rem_lanes < 16:
//       Lane in_rem_lanes receives the domain separation byte: state_reg[in_rem_lanes] ^= 64'h06.
//       Lane 16 (rate boundary) receives the MSB pad byte:     state_reg[16] ^= 64'h8000_0000_0000_0000.
//   - When in_rem_lanes == 16:
//       Padding starts and terminates within the same final rate lane:
//       state_reg[16] ^= (in_lane ^ 64'h8000_0000_0000_0006).
//
// Squeeze Phase:
//   Because digest length (256 bits) <= bit rate (1088 bits), the entire digest is obtained
//   in a single squeeze step directly from lanes A[0..3] (state_reg_q[255:0]) without requiring
//   any secondary permutation cycles.
//==================================================================================================

module sha3_256_core (
    // Global Clock and Reset
    input  logic         clk,           // Core clock signal
    input  logic         rst_n,         // Active-low asynchronous reset

    // Control Handshake
    input  logic         init,          // Initialize/reset sponge state to zero, ready for new message
    input  logic         in_valid,      // Input 64-bit lane valid strobe
    output logic         in_ready,      // Core ready to accept next 64-bit lane
    input  logic [63:0]  in_lane,       // 64-bit (8-byte) message input lane
    input  logic         in_last_block, // High if current block is the final block of the message
    input  logic [4:0]   in_rem_lanes,  // Number of valid message lanes in last block (15: k=2, 12: k=3, 9: k=4)

    // Digest Output Interface
    output logic         digest_valid,  // Asserted high when 256-bit hash digest is ready
    output logic [255:0] digest_out     // 256-bit SHA3-256 message digest (A[0..3])
);

    //----------------------------------------------------------------------------------------------
    // FSM State Encoding
    //----------------------------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE       = 3'd0,              // Quiescent state: awaiting init pulse
        ABSORB     = 3'd1,              // Ingesting 64-bit message lanes and applying padding
        PERM_MID   = 3'd2,              // Executing 24-cycle Keccak-f[1600] between multi-block absorbs
        PERM_FINAL = 3'd3,              // Executing 24-cycle Keccak-f[1600] on padded final block
        DONE       = 3'd4               // Squeezing: digest_valid asserted, holding digest_out
    } state_t;

    state_t state_q;

    //----------------------------------------------------------------------------------------------
    // Internal State and Counter Registers
    //----------------------------------------------------------------------------------------------
    logic [1599:0] state_reg_q;         // Sponge state register (25 x 64-bit lanes = 1600 bits)
    logic [4:0]    lane_cnt_q;          // Rate lane index counter within current block (0 to 16)

    //----------------------------------------------------------------------------------------------
    // Keccak-f[1600] Permutation Engine Interconnect
    //----------------------------------------------------------------------------------------------
    logic          core_start;          // Permutation start pulse to keccak_f1600 instance
    logic          core_ready;          // Keccak engine ready indicator
    logic          core_done;           // Keccak engine done pulse (asserted at cycle 24)
    wire  [1599:0] core_in;             // 1600-bit state input into keccak_f1600
    logic [1599:0] core_out;            // 1600-bit permuted state output from keccak_f1600

    // High-Performance 24-cycle Keccak-f[1600] permutation instance (1 round per cycle)
    keccak_f1600 #(.FAST_24(1)) keccak_inst (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (core_start),
        .load     (1'b1),
        .state_in (core_in),
        .ready    (core_ready),
        .done     (core_done),
        .state_out(core_out)
    );

    //----------------------------------------------------------------------------------------------
    // Continuous Interface Assignments
    //----------------------------------------------------------------------------------------------
    assign in_ready     = (state_q == ABSORB) && core_ready;
    assign digest_valid = (state_q == DONE);
    assign digest_out   = state_reg_q[255:0];   // Squeeze first 4 lanes (256 bits) of Keccak state
    assign core_in      = state_reg_q;

    //----------------------------------------------------------------------------------------------
    // Main Sequential Control Process (FSM, Lane Ingestion, and Padding Logic)
    //----------------------------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q     <= IDLE;
            state_reg_q <= '0;
            lane_cnt_q  <= 5'd0;
            core_start  <= 1'b0;
        end else begin
            core_start <= 1'b0;

            case (state_q)
                //----------------------------------------------------------------------------------
                // IDLE: Await initialization pulse to zero sponge state
                //----------------------------------------------------------------------------------
                IDLE: begin
                    if (init) begin
                        state_reg_q <= '0;
                        lane_cnt_q  <= 5'd0;
                        state_q     <= ABSORB;
                    end
                end

                //----------------------------------------------------------------------------------
                // ABSORB: Sequentially ingest 64-bit lanes, XOR into state, handle block boundaries
                //----------------------------------------------------------------------------------
                ABSORB: begin
                    if (init) begin
                        // Synchronous re-initialization
                        state_reg_q <= '0;
                        lane_cnt_q  <= 5'd0;
                        state_q     <= ABSORB;
                    end else if (in_valid && in_ready) begin
                        if (!in_last_block) begin
                            // Standard intermediate block absorption: 17 lanes (0 to 16)
                            state_reg_q[lane_cnt_q*64 +: 64] <= state_reg_q[lane_cnt_q*64 +: 64] ^ in_lane;
                            if (lane_cnt_q == 5'd16) begin
                                // Reached rate boundary (1088 bits): trigger intermediate Keccak permutation
                                core_start <= 1'b1;
                                lane_cnt_q <= 5'd0;
                                state_q    <= PERM_MID;
                            end else begin
                                lane_cnt_q <= lane_cnt_q + 1'b1;
                            end
                        end else begin
                            // Final message block absorption with SHA3 pad10*1 padding injection
                            state_reg_q[lane_cnt_q*64 +: 64] <= state_reg_q[lane_cnt_q*64 +: 64] ^ in_lane;
                            if (lane_cnt_q == in_rem_lanes - 1'b1) begin
                                // Reached last message lane of final block: inject domain byte (0x06) and MSB (0x80)
                                state_reg_q[in_rem_lanes*64 +: 64] <= state_reg_q[in_rem_lanes*64 +: 64] ^ 64'h06;
                                state_reg_q[16*64 +: 64]           <= (in_rem_lanes == 5'd16) ?
                                    (state_reg_q[16*64 +: 64] ^ in_lane ^ 64'h8000_0000_0000_0006) :
                                    (state_reg_q[16*64 +: 64] ^ 64'h8000_0000_0000_0000);
                                core_start <= 1'b1;
                                lane_cnt_q <= 5'd0;
                                state_q    <= PERM_FINAL;
                            end else begin
                                lane_cnt_q <= lane_cnt_q + 1'b1;
                            end
                        end
                    end
                end

                //----------------------------------------------------------------------------------
                // PERM_MID: Wait for 24-round Keccak-f[1600] to complete intermediate block
                //----------------------------------------------------------------------------------
                PERM_MID: begin
                    if (core_done) begin
                        state_reg_q <= core_out;
                        state_q     <= ABSORB;
                    end
                end

                //----------------------------------------------------------------------------------
                // PERM_FINAL: Wait for 24-round Keccak-f[1600] to complete final padded block
                //----------------------------------------------------------------------------------
                PERM_FINAL: begin
                    if (core_done) begin
                        state_reg_q <= core_out;
                        state_q     <= DONE;
                    end
                end

                //----------------------------------------------------------------------------------
                // DONE: Squeeze phase; digest is available on digest_out until next init
                //----------------------------------------------------------------------------------
                DONE: begin
                    if (init) begin
                        state_reg_q <= '0;
                        lane_cnt_q  <= 5'd0;
                        state_q     <= ABSORB;
                    end
                end

                default: state_q <= IDLE;
            endcase
        end
    end

endmodule
