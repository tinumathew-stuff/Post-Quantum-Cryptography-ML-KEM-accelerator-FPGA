`timescale 1ns/1ps

//==================================================================================================
// File: mlkem_ntt_intt.sv
// Module: mlkem_ntt_intt
//
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Specification: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism Standard)
// Target Frequency: 450+ MHz on AMD/Xilinx UltraScale+ FPGA Architecture
// Target Primitives: Pure Distributed RAM (SLICEM / LUTRAM / RAM32M), Zero BRAM/URAM Blocks
//
//==================================================================================================
// MATHEMATICAL FOUNDATION & ALGORITHMIC SPECIFICATION
//==================================================================================================
// ML-KEM operations are defined over the polynomial quotient ring:
//     R_q = Z_q[X] / (X^256 + 1)   where q = 3329
//
// Because X^256 + 1 factors into 128 quadratic polynomials over Z_q:
//     X^256 + 1 = \prod_{i=0}^{127} (X^2 - \zeta^{2 \cdot \text{BitRev}_7(i) + 1})
//
// The Number Theoretic Transform (NTT) maps a polynomial a(X) \in R_q with 256 coefficients
// into 128 degree-1 polynomials (pairs of coefficients) using 7 hierarchical butterfly stages:
//
// 1. Forward NTT: Cooley-Tukey Decimation-in-Time (DIT)
//    - 7 stages (Stage 0 to Stage 6)
//    - Butterfly equation:
//          A' = A + W * B  (mod q)
//          B' = A - W * B  (mod q)
//      where W = \zeta^{BitRev_7(group) + 1} is the Montgomery-domain twiddle factor.
//    - Number of butterflies: 7 stages * 128 butterflies/stage = 896 butterfly operations.
//    - At 8 parallel butterfly units, each stage requires exactly 16 issue cycles (112 total issues).
//
// 2. Inverse NTT (INTT): Gentleman-Sande Decimation-in-Frequency (DIF)
//    - 7 stages (Stage 6 down to Stage 0) followed by a coefficient normalization pass.
//    - Butterfly equation:
//          A' = A + B      (mod q)
//          B' = (A - B) * W (mod q)
//      where W = -\zeta^{BitRev_7(group) + 1} (mod q).
//    - Normalization Pass: Every coefficient must be scaled by n^{-1} = 128^{-1} \pmod{3329}.
//      In Montgomery form (R = 2^16), the multiplier is:
//          128^{-1} * R \pmod{3329} = 3303.
//      The normalization pass uses 32 issues through the butterfly array configured in pass-through/scale mode.
//
//==================================================================================================
// ARCHITECTURAL OVERVIEW & SUBSYSTEM DECOMPOSITION
//==================================================================================================
// +-----------------------------------------------------------------------------------------------+
// |                                    mlkem_ntt_intt Accelerator                                 |
// |                                                                                               |
// |  +-----------------------+     +-------------------------------+     +----------------------+ |
// |  | Input Stream Engine   |     | Parallel Butterfly Compute    |     | Output Stream Engine | |
// |  | - Ingestion (1/2/4 c) |     | - 8 parallel butterfly lanes  |     | - 2 coeffs/cycle     | |
// |  | - Format / range chk  |     | - Twiddle ROM lookup table    |     | - Skid prefetch reg  | |
// |  | - Modulo 3329 assert  |     | - 14-stage execution pipeline |     | - Handshake packing  | |
// |  +-----------+-----------+     +---------------+---------------+     +-----------^----------+ |
// |              |                                 |                                 |            |
// |              |                                 |                                 |            |
// |  +-----------v---------------------------------v---------------------------------+----------+ |
// |  |                    Decoupled 3-Slot Conflict-Free Distributed Memory                     | |
// |  |  +---------------------+   +---------------------+   +---------------------+             | |
// |  |  |  Slot 0 (256 coef)  |   |  Slot 1 (256 coef)  |   |  Slot 2 (256 coef)  |             | |
// |  |  |  8 Banks x 16 Words |   |  8 Banks x 16 Words |   |  8 Banks x 16 Words |             | |
// |  |  |  (State: LOAD)      |   |  (State: RUN)       |   |  (State: DONE)      |             | |
// |  |  +---------------------+   +---------------------+   +---------------------+             | |
// |  +------------------------------------------------------------------------------------------+ |
// +-----------------------------------------------------------------------------------------------+
//
// 1. Triple-Slot Buffer (Decoupled Load / Compute / Unload Pipeline):
//    - 3 independent memory slots (Slot 0, Slot 1, Slot 2).
//    - Each slot tracks its lifecycle: FREE -> LOAD -> READY -> RUN -> DONE -> FREE.
//    - Enables 100% duty cycle: while Slot K unloads to output, Slot (K+1)%3 executes NTT/INTT,
//      and Slot (K+2)%3 ingests the next incoming polynomial stream. Zero pipeline bubbles.
//
// 2. Conflict-Free 8-Bank Memory Architecture:
//    - 256 coefficients = 128 words (2 packed 12-bit coefficients per 24-bit word).
//    - Organized into 8 distributed RAM banks, each 16 rows deep (8 banks * 16 rows = 128 words).
//    - Banking hash:
//          bank = { ^word_addr[6:2], word_addr[1:0] }
//      Proof of Conflict-Freedom:
//      In any butterfly stage h (h \in 0..6), butterfly pairs are addressed as:
//          word_A = insert_side(wb, h)
//          word_B = word_A | (1 << h)
//      For h \in {0, 1}: The lowest 2 bits (word_addr[1:0]) differ between word_A and word_B,
//      ensuring they always map to distinct banks (low 2 bits differ).
//      For h \in {2, 3, 4, 5, 6}: Bit h is included in the XOR reduction ^word_addr[6:2],
//      ensuring bit 2 of bank changes between word_A and word_B.
//      Furthermore, across the 4 butterfly groups computed simultaneously in each cycle,
//      the lower bits wb[1:0] guarantee distinct banks across all 8 parallel words.
//      Hence, for ALL 7 DIT and DIF stages, zero bank collisions occur under all access patterns.
//
// 3. Parallel Butterfly Processing Array:
//    - 8 physical butterfly lanes (`mlkem_butterfly`):
//      * Arranged as 4 dual-lane butterfly units.
//      * Computes 8 coefficient pairs (16 coefficients = 8 words) per clock cycle.
//      * Lane 2*g processes low-half coefficients; Lane 2*g+1 processes high-half coefficients.
//      * 4 twiddle factors accessed combinatorially per issue cycle from `mlkem_twiddle.svh`.
//
// 4. Hazard-Free Execution & Cycle Timing:
//    - Butterfly pipeline depth = 14 clock cycles (`PIPE = 14`).
//    - 16 compute issues per stage (16 * 16 coefficients = 256 coefficients/stage).
//    - Minimum separation between stages = 14 clocks (6 dependency guard cycles inserted between
//      successive stages).
//    - Result: Writes from stage S commit to RAM strictly before stage S+1 reads them.
//      Completely eliminates Read-After-Write (RAW) data hazards without bypass multiplexers!
//    - Latency:
//      * Forward NTT: 112 compute issues + 36 guard cycles = 148 issue cycles.
//        Commit latency = 148 + 14 = 162 clock cycles.
//      * Inverse INTT: 112 compute issues + 32 normalization issues + 42 guard cycles = 186 issue cycles.
//        Commit latency = 186 + 14 = 200 clock cycles.
//==================================================================================================

module mlkem_ntt_intt (
    // Clock and active-low synchronous reset
    input  logic        clk,            // System clock (450 MHz nominal)
    input  logic        rst_n,          // Active-low synchronous reset

    // Command Interface (Control plane handshake)
    input  logic        cmd_valid,      // Command strobe: triggers new polynomial batch
    output logic        cmd_ready,      // Command ready: accelerator idle or ready for batch
    input  logic        cmd_mode,       // Transform mode: 0 = Forward NTT (DIT), 1 = Inverse INTT (DIF)
    input  logic [2:0]  cmd_k,          // ML-KEM parameter k: 2 (ML-KEM-512), 3 (ML-KEM-768), 4 (ML-KEM-1024)
    input  logic [4:0]  cmd_poly_count, // Batch size: number of polynomials to process (1 to 16)

    // Streaming Input Interface (Ingestion plane)
    input  logic        in_valid,       // Input data valid strobe
    output logic        in_ready,       // Input ready: high when buffer slot is ready for ingestion
    input  logic [23:0] in_data,        // Input word (carries up to two 12-bit coefficients: [11:0], [23:12])
    input  logic        in_wide = 1'b0, // Wide bus flag: when asserted, in_data_hi is also valid (4 coeffs/cycle)
    input  logic [23:0] in_data_hi = 24'd0, // High input word for wide ingestion bus ([11:0], [23:12])
    input  logic [1:0]  in_count,       // Number of valid coefficients in in_data (1 or 2)
    input  logic        in_last,        // End-of-polynomial beat flag (must align with 256th coefficient)
    input  logic [3:0]  in_poly_index,  // Expected polynomial index within batch (checked for protocol framing)

    // Streaming Output Interface (Egress plane)
    output logic        out_valid,      // Output data valid strobe
    input  logic        out_ready,      // Downstream backpressure: high when receiver is ready
    output logic [23:0] out_data,       // Output word containing two packed 12-bit transformed coefficients
    output logic [1:0]  out_count,      // Number of valid coefficients in out_data (always 2)
    output logic        out_last,       // End-of-polynomial beat flag (asserted on 128th output word)
    output logic [3:0]  out_poly_index, // Polynomial index of currently unloaded polynomial
    output logic        cmd_done,       // Batch completion strobe: pulsed high for 1 cycle upon completion
    output logic        cmd_error       // Protocol / range violation error flag
);
    // Include precomputed Montgomery twiddle factors (\zeta and -\zeta in bit-reversed order)
    `include "mlkem_twiddle.svh"

    // Slot Lifecycle State Encoding (Ping-Pong-Pang Triple Buffering)
    localparam logic [2:0] FREE=0,      // Slot is idle and available for input allocation
                           LOAD=1,      // Slot is actively receiving input coefficients from streaming bus
                           READY=2,     // Slot contains all 256 input coefficients; queued for execution
                           RUN=3,       // Slot is actively undergoing NTT / INTT computation in butterfly pipeline
                           DONE=4;      // Computation complete; slot contains results ready for streaming unload

    // Pipeline latency constant: 14 clock cycles from issue to RAM writeback commit
    localparam integer PIPE=14;

    // Slot state registers for the 3 memory slots
    logic [2:0] slot_state [0:2];

    // Control registers
    logic busy_q;                       // Accelerator busy flag: set when batch starts, cleared on completion
    logic inverse_q;                    // Registered transform mode: 0 = Forward NTT, 1 = Inverse INTT
    logic load_active_q;                // High while actively loading coefficients into current load slot
    logic issue_active_q;               // High while butterfly issue generator is sequencing a polynomial

    // Polynomial accounting counters
    logic [4:0] poly_count_q;           // Total polynomials in current command batch (1..16)
    logic [4:0] input_poly_q;           // Count of polynomials ingested so far
    logic [4:0] compute_poly_q;         // Count of polynomials whose compute has been issued
    logic [4:0] output_poly_q;          // Count of polynomials drained through output stream
    logic compute_poly_lt_count_q;      // Registered flag: compute_poly_q < poly_count_q
    logic input_poly_lt_count_q;        // Registered flag: input_poly_q < poly_count_q

    // Current slot pointers
    logic [1:0] load_slot_q;            // Slot index currently assigned to input ingestion
    logic [1:0] compute_slot_q;         // Slot index currently assigned to butterfly execution
    logic [1:0] output_slot_q;          // Slot index currently assigned to output stream draining

    // Address and issue counters
    logic [8:0] input_coeff_q;          // Ingested coefficient count within active polynomial (0 to 256)
    logic [8:0] issue_q;                // Butterfly issue index counter (0..207 for NTT, 0..255 for INTT)
    logic [6:0] output_word_q;          // Word read pointer for output draining (0 to 127 words = 256 coeffs)
    logic [11:0] pending_q;             // Holding register for orphan 12-bit coefficient when odd counts are streamed

    // RAM read data and bank routing pipeline registers
    logic [23:0] bank_read [0:7];              // Registered read data from 8 distributed RAM banks
    logic [23:0] bank_read_delay_q [0:7];      // Read data pipeline delay stage (matches address delay)
    logic [11:0] zeta_q [0:3];                 // Twiddle factor registers for 4 butterfly groups
    logic [6:0]  zeta_index_d_q [0:3];         // Delayed twiddle index pipeline registers
    logic [2:0] read_bank_q [0:7];             // Bank routing tags for read operand steering
    logic [2:0] read_bank_delay_q [0:7];       // Delayed bank routing tags
    logic [6:0] word_addr [0:7];               // 7-bit word address for 8 accessed memory locations
    logic [3:0] bank_row [0:7];                // 4-bit row address within each of the 8 banks
    logic [2:0] word_bank [0:7];               // Computed bank index for each of the 8 accessed words
    logic [6:0] zeta_index [0:3];              // Twiddle table lookup index for 4 butterfly groups

    // Pipeline tag tracking arrays (shift registers spanning PIPE=14 stages)
    logic [2:0] tag_bank [0:PIPE-1][0:7];      // Bank destination tag for writeback per lane
    logic [3:0] tag_row [0:PIPE-1][0:7];       // Row address destination tag for writeback per lane
    logic [1:0] tag_slot [0:PIPE-1];           // Destination memory slot tag along pipeline
    logic [PIPE-1:0] tag_valid;                // Valid issue qualification shift register
    logic [PIPE-1:0] tag_norm;                 // Normalization pass indicator shift register
    logic [PIPE-1:0] tag_last;                 // Last issue of polynomial indicator shift register

    // Butterfly operand and result arrays
    logic [11:0] bf_a [0:7], bf_b [0:7];       // 12-bit inputs to 8 butterfly lanes
    logic [11:0] bf_ra [0:7], bf_rb [0:7];     // 12-bit results from 8 butterfly lanes

    // Writeback routing and multiplexing
    logic [23:0] write_data [0:7];             // 24-bit packed writeback data per bank
    logic [3:0] write_row [0:7];               // Target row address per bank
    logic [7:0] write_enable;                  // Per-bank write enable strobes
    logic [23:0] compute_mem_out [0:2][0:7];   // Asynchronous distributed RAM read outputs for compute engine
    logic [23:0] output_mem_out [0:2][0:7];    // Asynchronous distributed RAM read outputs for output drain engine
    logic [3:0] read_row_q [0:7];              // Registered row addresses driving RAM read ports
    logic [6:0] zeta_index_q [0:3];            // Registered twiddle indices

    // Pipelined input stream writeback controls
    logic load_write_q;                        // Pipelined write strobe for low input word
    logic load_write_hi_q;                     // Pipelined write strobe for high input word (wide mode)
    logic [23:0] load_data_hi_q, accepted_data_hi_q; // Staged high-word input data
    logic accepted_wide_q;                     // Staged wide-word valid flag
    logic [2:0] load_bank_pipe_q;              // Pipelined destination bank for input write
    logic [1:0] load_slot_pipe_q;              // Pipelined destination slot for input write
    logic [3:0] load_row_pipe_q;               // Pipelined destination row for input write
    logic [23:0] load_data_pipe_q;             // Pipelined packed 24-bit input word

    // Registered writeback controls for distributed RAM
    logic [23:0] write_data_q [0:7];           // Registered write data to RAM banks
    logic [3:0] write_row_q [0:7];             // Registered row addresses for RAM writes
    logic [7:0] write_enable_q;                // Registered per-bank write enables
    logic [1:0] write_slot_q;                  // Registered target slot for writeback

    // Input staging registers
    logic accepted_valid_q, accepted_last_q, accepted_format_q;
    logic [23:0] accepted_data_q;
    logic [2:0] accepted_count_q;

    // Two-stage output prefetch / drain pipeline
    logic output_fetch_valid_q, output_fetch_last_q;
    logic [1:0] output_fetch_slot_q;
    logic [4:0] output_fetch_index_q;
    logic output_fetch_index_lt_poly_q;
    logic [2:0] output_fetch_bank_q;
    logic [3:0] output_fetch_poly_q;
    logic [23:0] output_fetch_data_q [0:7];

    // Boundary registers
    logic cmd_ready_q;
    logic [1:0] out_count_q;

    // Continuous interface assignments
    assign cmd_ready = cmd_ready_q;
    // in_ready asserts when accelerator is busy, slot loading is active, and no accepted end-of-packet stall
    assign in_ready  = busy_q && load_active_q && !(accepted_valid_q && accepted_last_q);
    assign out_count = out_count_q;

    // Flow control advancement strobes for output pipeline stages
    wire output_advance = !out_valid || out_ready;
    wire output_fetch_advance = !output_fetch_valid_q || output_advance;

    //----------------------------------------------------------------------------------------------
    // Function: is_ge_3329
    // Purpose: Fast bit-level comparator to verify that a 12-bit input coefficient is in canonical
    //          range [0, 3328]. Detects x >= 3329 without a full 12-bit carry-propagate subtractor.
    //          3329 = 12'b1101_0000_0001 (0xD01).
    //          x >= 3329 <=> (x[11:9] == 3'b111) OR (x[11:8] == 4'b1101 AND |x[7:0] != 0).
    //----------------------------------------------------------------------------------------------
    function automatic logic is_ge_3329(input logic [11:0] x);
        is_ge_3329 = (&x[11:9]) || ((x[11:8] == 4'b1101) && (|x[7:0]));
    endfunction

    // Input qualification and boundary error detection logic
    wire data_good = !is_ge_3329(accepted_data_q[11:0]) &&
                     (accepted_count_q == 1 || !is_ge_3329(accepted_data_q[23:12])) &&
                     (!accepted_wide_q || (!is_ge_3329(accepted_data_hi_q[11:0]) && !is_ge_3329(accepted_data_hi_q[23:12])));

    wire coeff_is_last = (input_coeff_q[7:2] == 6'b111111) &&
                         (accepted_wide_q ? (input_coeff_q[1:0] == 2'b00) :
                          accepted_count_q[1] ? (input_coeff_q[1:0] == 2'b10) :
                          (input_coeff_q[1:0] == 2'b11));

    wire input_good = accepted_format_q && data_good && !input_coeff_q[8] &&
                      !(accepted_count_q == 2 && input_coeff_q[7:0] == 255) &&
                      (!accepted_wide_q || input_coeff_q[1:0] == 0) &&
                      (accepted_last_q == coeff_is_last);

    wire input_fire = accepted_valid_q;

    //----------------------------------------------------------------------------------------------
    // Triple-Slot Lifecycle State Machine
    // Collapses clock-enable logic into 1-2 LUT levels for 450+ MHz timing closure.
    // State progression per slot:
    //   FREE  -> LOAD  : Ingestion starts when slot is FREE and input polynomials remain
    //   LOAD  -> READY : Exactly 256 coefficients loaded with valid framing
    //   READY -> RUN   : Butterfly compute engine allocates slot and begins issue sequence
    //   RUN   -> DONE  : Pipeline flushes last butterfly writeback to RAM (PIPE-1)
    //   DONE  -> FREE  : Output streaming engine completes draining 128 words with out_last
    //----------------------------------------------------------------------------------------------
    wire slot_load_start [0:2];
    wire slot_load_done  [0:2];
    wire slot_run_start  [0:2];
    wire slot_run_done   [0:2];
    wire slot_out_done   [0:2];

    for (genvar s=0; s<3; s++) begin: SLOT_CTRL_GEN
        assign slot_load_start[s] = busy_q && !load_active_q && input_poly_lt_count_q && (slot_state[s] == FREE) && (load_slot_q == 2'(s));
        assign slot_load_done[s]  = input_fire && input_good && accepted_last_q && (load_slot_q == 2'(s));
        assign slot_run_start[s]  = busy_q && !issue_active_q && compute_poly_lt_count_q && (slot_state[s] == READY) && (compute_slot_q == 2'(s));
        assign slot_run_done[s]   = tag_valid[PIPE-1] && tag_last[PIPE-1] && (tag_slot[PIPE-1] == 2'(s));
        assign slot_out_done[s]   = out_valid && out_ready && out_last && (output_slot_q == 2'(s));

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                slot_state[s] <= FREE;
            end else begin
                if (slot_load_start[s])
                    slot_state[s] <= LOAD;
                else if (slot_load_done[s])
                    slot_state[s] <= READY;
                else if (slot_run_start[s])
                    slot_state[s] <= RUN;
                else if (slot_run_done[s])
                    slot_state[s] <= DONE;
                else if (slot_out_done[s])
                    slot_state[s] <= FREE;
            end
        end
    end

    //----------------------------------------------------------------------------------------------
    // Issue Control & Stage Scheduling
    // Forward NTT: 7 stages x 16 issues = 112 issues.
    // Inverse INTT: 7 stages x 16 issues + 32 normalization issues = 144 issues.
    // Dependency guard spacing: 6 clocks between stages (issue_index[4:0] == 16..21).
    // RAW Hazard Freedom: 16 compute issues + 6 guard clocks = 22 clocks total per stage,
    // which strictly exceeds the 14-clock butterfly pipeline depth.
    //----------------------------------------------------------------------------------------------
    wire issue_start = slot_run_start[0] || slot_run_start[1] || slot_run_start[2];
    wire issue_tick = busy_q && (issue_active_q || issue_start);
    wire [8:0] issue_index = issue_q;
    wire normalizing = issue_index >= 9'd224;

    // Valid issue strobe: compute issues 0..15 of each stage, plus all normalization issues
    wire issue_valid = issue_tick && (normalizing || issue_index[4:0] < 16);
    wire [8:0] last_issue_idx = inverse_q ? 9'd255 : 9'd207;
    wire last_issue = issue_active_q && (issue_index == last_issue_idx);
    wire [2:0] stage_index = issue_index[7:5];
    wire [2:0] half_bit = inverse_q ? stage_index : (3'd6 - stage_index);
    wire [4:0] norm_issue = issue_index[4:0];
    wire [9:0] next_coeff = {1'b0, input_coeff_q} + {7'b0, accepted_count_q};

    // Input memory write address calculation
    wire load_write = input_fire && input_good && (input_coeff_q[0] || accepted_count_q >= 2);
    wire [6:0] load_word = input_coeff_q[7:1];
    wire [2:0] load_bank = {^load_word[6:2], load_word[1:0]};
    wire [6:0] output_addr = output_word_q;
    wire [2:0] output_bank = {^output_addr[6:2], output_addr[1:0]};

    // Helper function: modulo-3 slot pointer increment
    function automatic logic [1:0] next_slot(input logic [1:0] s);
        next_slot = (s == 2) ? 2'd0 : s + 1'b1;
    endfunction

    //----------------------------------------------------------------------------------------------
    // Function: insert_side
    // Purpose: Inserts a zero bit at position `h` into a 6-bit word index `wb`, expanding it to
    //          7-bit address. Used to generate the base address of butterfly pair A.
    //          The paired address B is simply (word_addr_A | (1 << h)).
    //----------------------------------------------------------------------------------------------
    function automatic logic [6:0] insert_side(input logic [5:0] wb, input logic [2:0] h);
        case (h)
            0: insert_side = {wb, 1'b0};
            1: insert_side = {wb[5:1], 1'b0, wb[0]};
            2: insert_side = {wb[5:2], 1'b0, wb[1:0]};
            3: insert_side = {wb[5:3], 1'b0, wb[2:0]};
            4: insert_side = {wb[5:4], 1'b0, wb[3:0]};
            5: insert_side = {wb[5], 1'b0, wb[4:0]};
            6: insert_side = {1'b0, wb};
            default: insert_side = 7'd0;
        endcase
    endfunction

    //----------------------------------------------------------------------------------------------
    // Function: table_index
    // Purpose: Computes the twiddle factor table index from butterfly group index and stage height.
    //          For inverse INTT, bits are inverted (wb ^ {6{inv}}) to match bit-reversed schedule.
    //----------------------------------------------------------------------------------------------
    function automatic logic [6:0] table_index(input logic [5:0] wb, input logic [2:0] h, input logic inv);
        logic [5:0] group_bits;
        group_bits = wb ^ {6{inv}};
        case (h)
            0: table_index = {1'b1, group_bits};
            1: table_index = {2'b01, group_bits[5:1]};
            2: table_index = {3'b001, group_bits[5:2]};
            3: table_index = {4'b0001, group_bits[5:3]};
            4: table_index = {5'b00001, group_bits[5:4]};
            5: table_index = {6'b000001, group_bits[5]};
            default: table_index = 7'd1;
        endcase
    endfunction

    //----------------------------------------------------------------------------------------------
    // Combinational Address Generation & Butterfly Routing
    // Computes memory addresses, bank mapping, and writeback routing for 8 parallel words per cycle.
    //----------------------------------------------------------------------------------------------
    always_comb begin
        // Generate 8 word addresses and 4 twiddle indices for the 4 butterfly groups
        for (int g=0; g<4; g++) begin
            word_addr[2*g]   = normalizing ? {norm_issue, 2'(g)} : insert_side({issue_index[3:0], 2'(g)}, half_bit);
            word_addr[2*g+1] = word_addr[2*g] | (7'b1 << half_bit);
            zeta_index[g]    = table_index({issue_index[3:0], 2'(g)}, half_bit, inverse_q);
        end

        // Calculate bank index using XOR hash: bank = { ^word_addr[6:2], word_addr[1:0] }
        for (int i=0; i<8; i++) begin
            word_bank[i] = {^word_addr[i][6:2], word_addr[i][1:0]};
            bank_row[i]  = 4'd0;
        end

        // Distribute row addresses to respective banks
        for (int i=0; i<8; i++)
            if (!normalizing || i%2 == 0) bank_row[word_bank[i]] = word_addr[i][6:3];

        // Route delayed read operands to 8 butterfly lanes
        for (int i=0; i<8; i++) begin
            bf_a[i]       = bank_read_delay_q[read_bank_delay_q[(i/2)*2]][(i%2)*12 +:12];
            bf_b[i]       = bank_read_delay_q[read_bank_delay_q[(i/2)*2+1]][(i%2)*12 +:12];
            write_data[i] = 24'd0;
            write_row[i]  = 4'd0;
        end

        // Route butterfly computation results to target bank write ports
        write_enable = 8'd0;
        for (int i=0; i<8; i++) begin
            if (!tag_norm[PIPE-2] || i%2 == 0) begin
                write_enable[tag_bank[PIPE-2][i]] = tag_valid[PIPE-2];
                write_row[tag_bank[PIPE-2][i]]    = tag_row[PIPE-2][i];
                if (tag_norm[PIPE-2] || i%2 == 0)
                    write_data[tag_bank[PIPE-2][i]] = {bf_ra[(i/2)*2+1], bf_ra[(i/2)*2]};
                else
                    write_data[tag_bank[PIPE-2][i]] = {bf_rb[(i/2)*2+1], bf_rb[(i/2)*2]};
            end
        end
    end

    //----------------------------------------------------------------------------------------------
    // Twiddle Factor Distributed ROM Lookup
    // Combinational lookup table returning 12-bit Montgomery twiddle constants from mlkem_twiddle.svh
    //----------------------------------------------------------------------------------------------
    logic [11:0] twiddle_data [0:3];
    for (genvar g=0; g<4; g++) begin: TWIDDLE_LOOKUP
        assign twiddle_data[g] = twiddle(inverse_q, zeta_index_d_q[g]);
    end

    //----------------------------------------------------------------------------------------------
    // Parallel Butterfly Execution Array (8 Butterfly Lanes / 4 Dual Units)
    // Instantiates 8 butterfly instances computing 8 coefficient pairs in parallel.
    // Each butterfly contains modular add/sub units and a Barrett/Montgomery modular multiplier.
    //----------------------------------------------------------------------------------------------
    for (genvar lane=0; lane<8; lane++) begin: BUTTERFLY
        mlkem_butterfly bf (
            .clk       (clk),
            .inverse   (inverse_q),
            .normalize (tag_norm[2]),
            .a         (bf_a[lane]),
            .b         (bf_b[lane]),
            .zeta      (zeta_q[lane/2]),
            .result_a  (bf_ra[lane]),
            .result_b  (bf_rb[lane])
        );
    end

    //----------------------------------------------------------------------------------------------
    // Memory Subsystem: 3 Slots x 8 Banks x 16 Rows x 24 bits
    // Explicitly synthesized into distributed RAM (SLICEM / LUTRAM / RAM32M primitives).
    // Strictly zero Block RAMs (BRAM) consumed.
    // Provides concurrent single-cycle read and synchronous write capabilities.
    //----------------------------------------------------------------------------------------------
    for (genvar s=0; s<3; s++) begin: SLOT
        for (genvar b=0; b<8; b++) begin: BANK
            (* ram_style = "distributed" *) logic [23:0] memory [0:15];
            assign compute_mem_out[s][b] = memory[read_row_q[b]];
            assign output_mem_out[s][b]  = memory[output_addr[6:3]];
            always_ff @(posedge clk) begin
                if (load_write_q && load_slot_pipe_q == s && load_bank_pipe_q == b)
                    memory[load_row_pipe_q] <= load_data_pipe_q;
                else if (load_write_hi_q && load_slot_pipe_q == s && (load_bank_pipe_q ^ 3'd1) == b)
                    memory[load_row_pipe_q] <= load_data_hi_q;
                else if (write_enable_q[b] && write_slot_q == s)
                    memory[write_row_q[b]] <= write_data_q[b];
            end
        end
    end

    //----------------------------------------------------------------------------------------------
    // Sequential Pipeline Process
    // Coordinates command decoding, input ingestion, butterfly issue scheduling, pipeline tag
    // propagation, memory writeback, output prefetching, and batch completion handshakes.
    //----------------------------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Synchronous reset state
            busy_q <= 0; inverse_q <= 0; load_active_q <= 0; issue_active_q <= 0;
            poly_count_q <= 0; input_poly_q <= 0; compute_poly_q <= 0; output_poly_q <= 0;
            compute_poly_lt_count_q <= 0; input_poly_lt_count_q <= 0;
            load_slot_q <= 0; compute_slot_q <= 0; output_slot_q <= 0;
            input_coeff_q <= 0; issue_q <= 0; output_word_q <= 0; pending_q <= 0;
            tag_valid <= 0; tag_norm <= 0; tag_last <= 0;
            cmd_done <= 0; cmd_error <= 0;
            out_valid <= 0; out_data <= 0; out_last <= 0; out_poly_index <= 0;
            load_write_q <= 0; load_write_hi_q <= 0;
            write_enable_q <= 0; accepted_valid_q <= 0;
            output_fetch_valid_q <= 0; output_fetch_slot_q <= 0; output_fetch_index_q <= 0;
            output_fetch_index_lt_poly_q <= 0;
            cmd_ready_q <= 1'b1;
            out_count_q <= 2'd2;
        end else begin
            // Default 1-cycle strobes
            cmd_done <= 0; cmd_error <= 0;
            out_count_q <= 2'd2;

            // Pipeline stage 0: Input stream sample and register
            accepted_valid_q  <= in_valid && in_ready;
            accepted_data_q   <= in_data;
            accepted_count_q  <= in_wide ? 3'd4 : {1'b0, in_count};
            accepted_last_q   <= in_last;
            accepted_data_hi_q <= in_data_hi;
            accepted_wide_q   <= in_wide;
            accepted_format_q <= (in_wide || in_count==1 || in_count==2) && in_poly_index==input_poly_q[3:0];

            // Pipeline tag tracking: Shift valid, normalization, and last-issue flags
            tag_valid   <= {tag_valid[PIPE-2:0], issue_valid};
            tag_norm    <= {tag_norm[PIPE-2:0], normalizing};
            tag_last    <= {tag_last[PIPE-2:0], last_issue};
            tag_slot[0] <= compute_slot_q;

            // Pipeline stage 1: Bank read and memory address staging
            for (int b=0; b<8; b++) begin
                bank_read[b]         <= compute_mem_out[tag_slot[0]][b];
                bank_read_delay_q[b] <= bank_read[b];
                read_bank_q[b]       <= tag_bank[0][b];
                read_bank_delay_q[b] <= read_bank_q[b];
                read_row_q[b]        <= bank_row[b];
                tag_bank[0][b]       <= word_bank[b];
                tag_row[0][b]        <= word_addr[b][6:3];
                write_data_q[b]      <= write_data[b];
                write_row_q[b]       <= write_row[b];
            end

            // Propagate pipeline tags through remaining stages (1 to PIPE-1)
            for (int p=1; p<PIPE; p++) begin
                tag_slot[p] <= tag_slot[p-1];
                for (int b=0; b<8; b++) begin
                    tag_bank[p][b] <= tag_bank[p-1][b];
                    tag_row[p][b]  <= tag_row[p-1][b];
                end
            end

            // Twiddle factor pipeline staging: inject Montgomery constant 3303 during normalization
            for (int g=0; g<4; g++) begin
                zeta_index_q[g]   <= zeta_index[g];
                zeta_index_d_q[g] <= zeta_index_q[g];
                zeta_q[g]         <= tag_norm[1] ? 12'd3303 : twiddle_data[g];
            end

            // Writeback stage controls
            write_enable_q   <= write_enable;
            write_slot_q     <= tag_slot[PIPE-2];
            load_write_q     <= load_write;
            load_write_hi_q  <= load_write && accepted_wide_q;
            load_data_hi_q   <= accepted_data_hi_q;
            load_slot_pipe_q <= load_slot_q;
            load_bank_pipe_q <= load_bank;
            load_row_pipe_q  <= load_word[6:3];
            load_data_pipe_q <= input_coeff_q[0] ? {accepted_data_q[11:0], pending_q} : accepted_data_q;

            // Command interface handling
            if (cmd_valid && cmd_ready_q) begin
                if ((cmd_k >= 3'd2 && cmd_k <= 3'd4) && cmd_poly_count >= 5'd1 && cmd_poly_count <= 5'd16) begin
                    busy_q                       <= 1;
                    inverse_q                    <= cmd_mode;
                    poly_count_q                 <= cmd_poly_count;
                    compute_poly_lt_count_q      <= 1;
                    input_poly_lt_count_q        <= 1;
                    output_fetch_index_lt_poly_q <= 1;
                    cmd_ready_q                  <= 1'b0;
                end else begin
                    cmd_error                    <= 1;
                    cmd_done                     <= 1;
                    output_fetch_index_lt_poly_q <= 0;
                    compute_poly_lt_count_q      <= 0;
                    input_poly_lt_count_q        <= 0;
                    cmd_ready_q                  <= 1'b1;
                end
            end

            // Input slot allocation
            if (busy_q && !load_active_q && input_poly_lt_count_q && slot_state[load_slot_q] == FREE) begin
                load_active_q <= 1;
                input_coeff_q <= 0;
            end

            // Input coefficient packing and verification
            if (input_fire && !input_good) cmd_error <= 1;
            if (input_fire && input_good) begin
                input_coeff_q <= next_coeff[8:0];
                pending_q     <= input_coeff_q[0] && accepted_count_q == 2 ? accepted_data_q[23:12] : accepted_data_q[11:0];
                if (accepted_last_q) begin
                    load_active_q         <= 0;
                    load_slot_q           <= next_slot(load_slot_q);
                    input_poly_q          <= input_poly_q + 1'b1;
                    input_poly_lt_count_q <= ({1'b0, input_poly_q} + 6'd1 < {1'b0, poly_count_q});
                end
            end

            // Compute slot advance upon issuing final butterfly of polynomial
            if (last_issue) begin
                compute_slot_q          <= next_slot(compute_slot_q);
                compute_poly_q          <= compute_poly_q + 1'b1;
                compute_poly_lt_count_q <= ({1'b0, compute_poly_q} + 6'd1 < {1'b0, poly_count_q});
            end

            // Issue counter stepping with automatic 6-clock dependency guard cycle insertion
            if (issue_tick) begin
                issue_active_q <= !last_issue;
                issue_q        <= last_issue ? 9'd0 : (!normalizing && issue_index[4:0] == 21 ? issue_index+9'd11 : issue_index+1'b1);
            end

            // Output stage 1: Prefetch word from completed distributed RAM slot
            if (output_fetch_advance) begin
                output_fetch_valid_q <= busy_q && slot_state[output_fetch_slot_q] == DONE && output_fetch_index_lt_poly_q;
                for (int b=0; b<8; b++) begin
                    output_fetch_data_q[b] <= output_mem_out[output_fetch_slot_q][b];
                end
                output_fetch_bank_q <= output_bank;
                output_fetch_last_q <= output_word_q == 127;
                output_fetch_poly_q <= output_fetch_index_q[3:0];
                if (busy_q && slot_state[output_fetch_slot_q] == DONE && output_fetch_index_lt_poly_q) begin
                    output_word_q <= output_word_q + 1'b1;
                    if (output_word_q == 127) begin
                        output_fetch_slot_q          <= next_slot(output_fetch_slot_q);
                        output_fetch_index_q         <= output_fetch_index_q + 1'b1;
                        output_fetch_index_lt_poly_q <= ({1'b0, output_fetch_index_q} + 6'd1 < {1'b0, poly_count_q});
                    end
                end
            end

            // Output stage 2: Drive registered streaming output pins with backpressure support
            if (output_advance) begin
                out_valid      <= output_fetch_valid_q;
                out_data       <= output_fetch_data_q[output_fetch_bank_q];
                out_last       <= output_fetch_last_q;
                out_poly_index <= output_fetch_poly_q;
                if (out_valid && out_ready && out_last) begin
                    output_slot_q <= next_slot(output_slot_q);
                    output_poly_q <= output_poly_q + 1'b1;
                    // Check if entire batch of polynomials has finished unloading
                    if (output_poly_q + 1'b1 == poly_count_q) begin
                        busy_q                       <= 0;
                        cmd_done                     <= 1;
                        cmd_ready_q                  <= 1'b1;
                        load_slot_q                  <= 0;
                        compute_slot_q               <= 0;
                        output_slot_q                <= 0;
                        input_poly_q                 <= 0;
                        compute_poly_q               <= 0;
                        output_poly_q                <= 0;
                        input_poly_lt_count_q        <= 0;
                        compute_poly_lt_count_q      <= 0;
                        output_fetch_slot_q          <= 0;
                        output_fetch_index_q         <= 0;
                    end
                end
            end
        end
    end
endmodule
