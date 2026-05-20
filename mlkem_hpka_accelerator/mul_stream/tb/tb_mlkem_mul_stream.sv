`timescale 1ns/1ps

//==================================================================================================
// File: tb_mlkem_mul_stream.sv
// Module: tb_mlkem_mul_stream
//
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Specification: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism Standard)
// Target Frequency: 450 MHz (Clock period = 2.222 ns)
//
//==================================================================================================
// MATHEMATICAL BACKGROUND & DYADIC BASE MULTIPLICATION
//==================================================================================================
// In ML-KEM (FIPS 203), polynomial multiplication in the Number Theoretic Transform (NTT) domain
// is defined over the ring:
//     R_q = Z_q[X] / (X^256 + 1)   where q = 3329
//
// Since X^256 + 1 does not factor into linear binomials in Z_3329, it splits into 128 irreducible
// quadratic factors:
//     X^256 + 1 = \prod_{i=0}^{127} (X^2 - \zeta^{2 \cdot \text{BitRev}_7(i) + 1})
//
// Therefore, multiplication of two polynomials \hat{u}, \hat{v} \in R_q in the NTT domain
// consists of 128 parallel degree-1 polynomial "base multiplications" (dyadic products):
//     (c_0 + c_1 X) = (a_0 + a_1 X) * (b_0 + b_1 X)  mod (X^2 - \zeta)
//
// Expanding modulo (X^2 - \zeta):
//     c_0 = a_0 * b_0 + a_1 * b_1 * \zeta  (mod 3329)
//     c_1 = a_0 * b_1 + a_1 * b_0          (mod 3329)
//
// Matrix-Vector and Vector-Vector Inner Products:
// For Kyber parameter k \in {2, 3, 4}, matrix-vector multiplication requires computing:
//     \mathbf{w} = \hat{\mathbf{A}} \circ \hat{\mathbf{s}} = \sum_{j=0}^{k-1} \hat{A}_{i,j} \circ \hat{s}_j
// This requires accumulating dyadic products across k polynomial vector components.
//
// DUT Architecture (`mlkem_mul_stream`):
// - 4-way parallel datapath: computes 2 base multiplications (4 coefficients: c0, c1, c2, c3) per cycle.
// - Pipelined Montgomery multipliers with modular reduction modulo 3329.
// - Accumulator bank: maintains running partial sums across matrix rows/columns.
// - Decoupled credit-based FIFO queueing with independent streaming handshake interfaces.
//
//==================================================================================================
// TESTBENCH STRUCTURE & VERIFICATION STRATEGY
//==================================================================================================
// This testbench performs exhaustive, bit-exact verification against Known Answer Tests (KAT)
// generated from the Stockham reference algorithmic model:
//
// 1. Comprehensive Test Stimulus:
//    - Loads `mul_vectors_4way.txt` containing up to 28,000 test beats.
//    - Exercises all operational modes, security parameters (k = 2, 3, 4), and accumulation states.
//
// 2. Multi-Phase Protocol Stress Testing:
//    - Phase 1: Baseline Full Throughput (No backpressure; m_ready=1; validates peak compute rate).
//    - Phase 2: Dynamic Random Backpressure & Bubbles (LFSR-driven ~68% throughput; injects input stalls).
//    - Phase 3: Heavy Burst Backpressure (Stalls lasting 20-50 cycles; tests FIFO saturation and credit exhaustion).
//    - Phase 4: High-Frequency Alternating Backpressure (1-on-1-off 50% duty cycle handshake stress).
//
// 3. Hardware Protocol Invariants & Safety Assertions:
//    - Output Payload Invariance: Asserts output signals remain identical across stall cycles.
//    - FIFO Depth Bound: Asserts internal storage depth never exceeds 32 words (`dut.stored <= 32`).
//    - Credit Reservation Bound: Asserts credit reservation counter never exceeds 32 (`dut.reserved <= 32`).
//==================================================================================================

module tb_mlkem_mul_stream;
    // Clock generation: 450 MHz nominal frequency (period = 2.222 ns; half-period = 1.111 ns)
    logic clk = 0;
    always #1.111 clk = ~clk; // 450 MHz clock

    // Synchronous active-high reset
    logic rst = 1;

    // Streaming Slave Interface (Input Stimulus)
    logic s_valid = 0;                  // Input valid strobe
    logic s_ready;                      // DUT ready to accept input beat
    logic s_start = 0;                  // Start-of-operation strobe (clears/initializes accumulator)
    logic s_accumulate = 0;             // Accumulate strobe: 1 = add to running sum, 0 = overwrite
    logic [1:0] s_mode = 0;             // Multiplier mode (0: matrix-vector, 1: vector-vector, etc.)
    logic [2:0] s_k = 2;                // ML-KEM parameter k (2, 3, or 4)
    logic [5:0] s_base_index = 0;       // Base polynomial index (0 to 63, addressing 128 dyadic pairs)

    // 4 parallel input operand pairs (13-bit signed modular values)
    // Pair 0: (a0 + a1*X) * (b0 + b1*X)
    logic signed [12:0] s_a0 = 0, s_a1 = 0, s_b0 = 0, s_b1 = 0;
    // Pair 1: (a2 + a3*X) * (b2 + b3*X)
    logic signed [12:0] s_a2 = 0, s_a3 = 0, s_b2 = 0, s_b3 = 0;

    // Streaming Master Interface (Output Results)
    logic m_valid;                      // Output result valid strobe
    logic m_ready = 1;                  // Downstream ready backpressure signal
    logic signed [11:0] m_c0, m_c1, m_c2, m_c3; // 4 resulting 12-bit modular coefficients
    logic [5:0] m_index;                // Output base index (0 to 63)
    logic [1:0] m_row;                  // Matrix row identifier
    logic m_last;                       // End-of-packet/matrix inner product flag

    // Device Under Test (DUT) Instantiation
    mlkem_mul_stream dut (
        .clk(clk),
        .rst(rst),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_start(s_start),
        .s_accumulate(s_accumulate),
        .s_mode(s_mode),
        .s_k(s_k),
        .s_base_index(s_base_index),
        .s_a0(s_a0), .s_a1(s_a1), .s_b0(s_b0), .s_b1(s_b1),
        .s_a2(s_a2), .s_a3(s_a3), .s_b2(s_b2), .s_b3(s_b3),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_c0(m_c0), .m_c1(m_c1), .m_c2(m_c2), .m_c3(m_c3),
        .m_index(m_index),
        .m_row(m_row),
        .m_last(m_last)
    );

    //----------------------------------------------------------------------------------------------
    // Protocol Stability & Hardware Safety Assertions
    // Continuously monitors output port consistency and internal FIFO capacity limits.
    //----------------------------------------------------------------------------------------------
    logic held_valid;
    logic [56:0] held_payload;
    integer cycle_total = 0;

    always_ff @(posedge clk) begin
        if (!rst) begin
            cycle_total <= cycle_total + 1;

            // Protocol Assertion: Output payload must NOT mutate while stalled under backpressure
            if (held_valid && !m_ready) begin
                if (!m_valid || {m_last, m_row, m_index, m_c3, m_c2, m_c1, m_c0} !== held_payload) begin
                    $fatal(1, "PROTOCOL VIOLATION: Output payload changed during stall at cycle %0d!", cycle_total);
                end
            end
            held_valid <= m_valid && !m_ready;
            held_payload <= {m_last, m_row, m_index, m_c3, m_c2, m_c1, m_c0};

            // Structural Safety Assertions: Internal FIFO and Credit bounds
            if (dut.stored > 32) begin
                $fatal(1, "FIFO OVERFLOW: stored=%0d > 32 at cycle %0d!", dut.stored, cycle_total);
            end
            if (dut.reserved > 32) begin
                $fatal(1, "CREDIT OVERFLOW: reserved=%0d > 32 at cycle %0d!", dut.reserved, cycle_total);
            end
        end else begin
            held_valid <= 0;
        end
    end

    //----------------------------------------------------------------------------------------------
    // Golden Test Vector Storage Arrays
    //----------------------------------------------------------------------------------------------
    localparam MAX_BEATS = 28000;
    localparam MAX_RESULTS = 12000;
    integer data [0:MAX_BEATS-1][0:20];         // Raw input stimulus matrix
    logic [56:0] expected [0:MAX_RESULTS-1];    // Packed golden result vector
    integer total_beats = 0;
    integer total_results = 0;

    //----------------------------------------------------------------------------------------------
    // Galois LFSR for Randomized Backpressure & Input Bubbles
    // Polynomial: x^16 + x^14 + x^13 + x^11 + 1 (period = 65,535)
    //----------------------------------------------------------------------------------------------
    logic [15:0] lfsr = 16'hace1;
    function automatic logic [15:0] step_lfsr(logic [15:0] state);
        return {state[14:0], state[15] ^ state[13] ^ state[12] ^ state[10]};
    endfunction

    //----------------------------------------------------------------------------------------------
    // Task: run_phase
    // Purpose: Executes a complete verification phase across all loaded test beats with a
    //          specified backpressure and bubble injection profile:
    //            stall_mode = 0: None (full line-rate throughput)
    //            stall_mode = 1: Dynamic LFSR pseudorandom backpressure & bubbles (~68% rate)
    //            stall_mode = 2: Heavy burst backpressure (20-50 stall cycles, testing credit recovery)
    //            stall_mode = 3: Alternating 1-on-1-off backpressure (50% toggle)
    //----------------------------------------------------------------------------------------------
    task automatic run_phase(
        input int phase_id,
        input string phase_name,
        input int stall_mode // 0: None, 1: Random LFSR, 2: Heavy Bursts, 3: Alternating
    );
        integer sent, rd, phase_cycles, stall_cycles, bubble_cycles, burst_counter;
        logic current_m_ready, current_s_valid;

        $display("--------------------------------------------------------------------------------");
        $display("Starting Phase %0d: %s", phase_id, phase_name);
        $display("--------------------------------------------------------------------------------");

        // Clean synchronous reset sequence
        @(negedge clk);
        rst = 1;
        s_valid = 0;
        m_ready = 1;
        repeat (5) @(negedge clk);
        rst = 0;
        @(negedge clk);

        sent = 0;
        rd = 0;
        phase_cycles = 0;
        stall_cycles = 0;
        bubble_cycles = 0;
        burst_counter = 0;

        while (sent < total_beats || rd < total_results) begin
            // 1. Determine backpressure profile on negative clock edge
            lfsr = step_lfsr(lfsr);
            case (stall_mode)
                0: current_m_ready = 1'b1;
                1: current_m_ready = (lfsr[3:0] < 4'd11); // ~68% throughput
                2: begin
                    // Burst pattern: 20 to 50 stall cycles every ~120 cycles
                    if (burst_counter > 0) begin
                        burst_counter = burst_counter - 1;
                        current_m_ready = 1'b0;
                    end else if ((lfsr[7:0] < 8'd25) && (sent < total_beats - 200)) begin
                        burst_counter = 20 + (lfsr[3:0] * 2); // 20 to 50 stall cycles
                        current_m_ready = 1'b0;
                    end else begin
                        current_m_ready = 1'b1;
                    end
                end
                3: current_m_ready = ~current_m_ready; // 50% 1-on-1-off alternating
                default: current_m_ready = 1'b1;
            endcase

            // Random input bubbles for stress testing (in stall modes 1 and 2)
            if (sent < total_beats) begin
                if ((stall_mode == 1 && (lfsr[6:4] == 3'b000)) ||
                    (stall_mode == 2 && (lfsr[9:8] == 2'b00 && burst_counter == 0))) begin
                    current_s_valid = 1'b0;
                    bubble_cycles = bubble_cycles + 1;
                end else begin
                    current_s_valid = 1'b1;
                end
            end else begin
                current_s_valid = 1'b0;
            end

            // Drive stimulus inputs synchronously to DUT
            m_ready <= current_m_ready;
            s_valid <= current_s_valid;
            if (current_s_valid && sent < total_beats) begin
                s_start       <= data[sent][0];
                s_mode        <= data[sent][1][1:0];
                s_k           <= data[sent][2][2:0];
                s_base_index  <= data[sent][3][5:0];
                s_a0          <= data[sent][4][12:0];
                s_a1          <= data[sent][5][12:0];
                s_a2          <= data[sent][6][12:0];
                s_a3          <= data[sent][7][12:0];
                s_b0          <= data[sent][8][12:0];
                s_b1          <= data[sent][9][12:0];
                s_b2          <= data[sent][10][12:0];
                s_b3          <= data[sent][11][12:0];
                s_accumulate  <= data[sent][20][0];
            end

            // 2. Advance to positive clock edge where state updates
            @(posedge clk);
            phase_cycles = phase_cycles + 1;

            if (m_valid && !m_ready) begin
                stall_cycles = stall_cycles + 1;
            end

            // Check if input beat was accepted by slave handshake
            if (s_valid && s_ready) begin
                sent = sent + 1;
            end

            // Check and verify output beat against Stockham KAT reference
            if (m_valid && m_ready) begin
                logic [56:0] got;
                got = {m_last, m_row, m_index, m_c3, m_c2, m_c1, m_c0};
                if (got !== expected[rd]) begin
                    $fatal(1, "MISMATCH at Phase %0d result %0d (cycle %0d): got={last=%0d, row=%0d, idx=%0d, c0=%03x, c1=%03x, c2=%03x, c3=%03x} exp={last=%0d, row=%0d, idx=%0d, c0=%03x, c1=%03x, c2=%03x, c3=%03x}",
                        phase_id, rd, phase_cycles,
                        m_last, m_row, m_index, m_c0[11:0], m_c1[11:0], m_c2[11:0], m_c3[11:0],
                        expected[rd][56], expected[rd][55:54], expected[rd][53:48],
                        expected[rd][11:0], expected[rd][23:12], expected[rd][35:24], expected[rd][47:36]);
                end
                rd = rd + 1;
            end

            // 3. Return to negative clock edge for next cycle stimulus setup
            @(negedge clk);
        end

        $display("Phase %0d PASSED: %0d/%0d results bit-exact! (Elapsed=%0d cc, Stalls=%0d cc, Bubbles=%0d cc)",
            phase_id, rd, total_results, phase_cycles, stall_cycles, bubble_cycles);
    endtask

    //----------------------------------------------------------------------------------------------
    // Main Verification Process
    //----------------------------------------------------------------------------------------------
    initial begin
        integer fd, rc;
        // Open precomputed Stockham reference Known Answer Test (KAT) vector file
        fd = $fopen("mul_vectors_4way.txt", "r");
        if (!fd) begin
            $fatal(1, "Failed to open mul_vectors_4way.txt!");
        end

        // Parse vector file columns
        while (!$feof(fd) && total_beats < MAX_BEATS) begin
            rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
                data[total_beats][0],  data[total_beats][1],  data[total_beats][2],  data[total_beats][3],
                data[total_beats][4],  data[total_beats][5],  data[total_beats][6],  data[total_beats][7],
                data[total_beats][8],  data[total_beats][9],  data[total_beats][10], data[total_beats][11],
                data[total_beats][12], data[total_beats][13], data[total_beats][14], data[total_beats][15],
                data[total_beats][16], data[total_beats][17], data[total_beats][18], data[total_beats][19],
                data[total_beats][20]);
            if (rc == 21) begin
                // Column 12 indicates whether this beat yields a valid output result
                if (data[total_beats][12]) begin
                    expected[total_results] = {
                        data[total_beats][19][0], data[total_beats][18][1:0], data[total_beats][17][5:0],
                        data[total_beats][16][11:0], data[total_beats][15][11:0], data[total_beats][14][11:0], data[total_beats][13][11:0]
                    };
                    total_results = total_results + 1;
                end
                total_beats = total_beats + 1;
            end
        end
        $fclose(fd);
        $display("Loaded %0d test beats, expecting %0d results (%0d coefficients) from Stockham reference KAT.",
            total_beats, total_results, total_results * 4);

        // Execute 4 Comprehensive Verification Phases
        // Phase 1: Baseline Full Throughput (No backpressure)
        run_phase(1, "Baseline Full Throughput (No Backpressure)", 0);

        // Phase 2: Dynamic Random Backpressure + Input Bubbles
        run_phase(2, "Dynamic Random Backpressure & Bubbles", 1);

        // Phase 3: Heavy Burst Backpressure (Credit Exhaustion & FIFO Squeeze)
        run_phase(3, "Heavy Burst Backpressure (Credit Exhaustion & Saturation)", 2);

        // Phase 4: Alternating 1-on-1-off Backpressure
        run_phase(4, "High-Frequency 1-on-1-off Backpressure", 3);

        // Final verification summary banner
        $display("================================================================================");
        $display("ALL 4 VERIFICATION PHASES PASSED 100%% BIT-EXACT!");
        $display("Total vectors verified across 4 phases: %0d (%0d coefficients)",
                 total_results * 4, total_results * 16);
        $display("================================================================================");
        $finish;
    end
endmodule
