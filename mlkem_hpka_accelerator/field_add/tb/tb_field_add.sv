// =============================================================================
// File: tb_field_add.sv
// Module: tb_field_add
// Project: ML-KEM High-Performance Cryptographic Hardware Accelerator (HPKA)
// Standard: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Target Frequency: 450 MHz (Clock Period T ~ 2.222 ns)
// =============================================================================
//
// Description:
// ------------
// Comprehensive verification testbench for the `field_add` modular addition
// unit. This environment executes 7,724 pre-computed test vectors spanning all
// algebraic boundary cases, arithmetic overflows, and pseudo-random field
// distributions modulo q = 3329.
//
// Verification Methodology:
// -------------------------
// 1. Dual Independent Concurrent Processes (Producer-Consumer):
//    The test driver (`run_test_segment`) forks two concurrent execution threads:
//    - Sender Thread (Producer): Drives `in_valid`, `in_a`, `in_b`, and `in_last`
//      in accordance with the active backpressure profile. Holds signals stable
//      until an accepted handshake (`in_valid && in_ready`) occurs at `posedge clk`.
//    - Receiver Thread (Consumer): Emulates downstream sink backpressure by
//      modulating `out_ready`. When an output transfer completes (`out_valid && out_ready`),
//      it strictly verifies payload equality (`out_data === expected`) and packet
//      framing alignment (`out_last === exp_last`).
//
// 2. Race-Free Timing Discipline:
//    Stimulus and control signals (`in_valid`, `in_a`, `in_b`, `in_last`, `out_ready`)
//    are driven on `@(negedge clk)` and handshakes are evaluated on `@(posedge clk)`.
//    This ensures zero delta-cycle race conditions and provides realistic setup/hold
//    margins during RTL and gate-level simulation.
//
// 3. Exhaustive Traffic Stress Profiles (7 Distinct Backpressure Modes):
//    - Phase 0: BP_NONE - 100% back-to-back sustained throughput (zero bubbles).
//    - Phase 1: BP_SINK_PINGPONG - Downstream toggles ready every cycle (50% duty).
//    - Phase 2: BP_SINK_HEAVY_90 - Severe downstream congestion (~85% stall probability).
//    - Phase 3: BP_SINK_BURST - Bursty consumer (7 cycles accept, 23 cycles stall).
//    - Phase 4: BP_SRC_STARVE - Starved producer (~20% valid density).
//    - Phase 5: BP_SRC_BURST - Bursty producer (8 cycles send, 17 cycles idle).
//    - Phase 6: BP_COMBINED_RANDOM - Simultaneous bidirectional randomized stress.
//
// 4. Hardware Skid Buffer Verification:
//    Validates that no beats are dropped, duplicated, or corrupted when backpressure
//    is asserted while the module is processing back-to-back streaming inputs.
//
// =============================================================================

`timescale 1ns/1ps

module tb_field_add;

    // -------------------------------------------------------------------------
    // Testbench Parameters & Mathematical Modulus
    // -------------------------------------------------------------------------
    localparam int DATA_WIDTH    = 12;      // 12-bit coefficients for ML-KEM
    localparam logic [DATA_WIDTH-1:0] Q = 12'd3329; // Modulus q = 3329
    localparam int TOTAL_VECTORS = 7724;    // Total vectors in test suite

    // -------------------------------------------------------------------------
    // Clock & Reset Generator (450 MHz Target)
    // -------------------------------------------------------------------------
    // Half-period 1.111 ns yields a full period of 2.222 ns (~450.045 MHz)
    logic clk = 0;
    always #1.111 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT Interconnect Signals
    // -------------------------------------------------------------------------
    logic                  rst_n = 0;       // Asynchronous active-low reset
    logic                  in_valid = 0;    // Upstream streaming valid
    logic                  in_ready;        // DUT streaming ready feedback
    logic [DATA_WIDTH-1:0] in_a = 0;        // Operand A
    logic [DATA_WIDTH-1:0] in_b = 0;        // Operand B
    logic                  in_last = 0;     // Upstream packet framing / vector end

    logic                  out_valid;       // DUT streaming valid output
    logic                  out_ready = 0;   // Downstream ready backpressure
    logic [DATA_WIDTH-1:0] out_data;        // DUT modular addition result
    logic                  out_last;        // DUT output packet framing indicator

    // -------------------------------------------------------------------------
    // Golden Reference Vector Storage
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0] vec_a    [0:TOTAL_VECTORS-1]; // Input vector array for operand A
    logic [DATA_WIDTH-1:0] vec_b    [0:TOTAL_VECTORS-1]; // Input vector array for operand B
    logic [DATA_WIDTH-1:0] expected [0:TOTAL_VECTORS-1]; // Golden expected modular sum array

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    // -------------------------------------------------------------------------
    field_add #(
        .DATA_WIDTH (DATA_WIDTH),
        .Q          (Q)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_ready  (in_ready),
        .in_a      (in_a),
        .in_b      (in_b),
        .in_last   (in_last),
        .out_valid (out_valid),
        .out_ready (out_ready),
        .out_data  (out_data),
        .out_last  (out_last)
    );

    // -------------------------------------------------------------------------
    // Test Vector File Loading
    // Supports relative paths whether executed from workspace root or build/
    // -------------------------------------------------------------------------
    initial begin
        int f;
        string path_a, path_b, path_exp;
        f = $fopen("field_add/tb/input_a.hex", "r");
        if (f) begin
            $fclose(f);
            path_a   = "field_add/tb/input_a.hex";
            path_b   = "field_add/tb/input_b.hex";
            path_exp = "field_add/tb/expected.hex";
        end else begin
            path_a   = "../field_add/tb/input_a.hex";
            path_b   = "../field_add/tb/input_b.hex";
            path_exp = "../field_add/tb/expected.hex";
        end
        $readmemh(path_a, vec_a);
        $readmemh(path_b, vec_b);
        $readmemh(path_exp, expected);
        $display("[INFO] Loaded test vectors from %s", path_a);
    end

    // -------------------------------------------------------------------------
    // Simulation Watchdog Timer
    // Aborts simulation if deadlock occurs or transfers hang past 500,000 cycles
    // -------------------------------------------------------------------------
    integer cycle_count = 0;
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > 500000) begin
            $fatal(1, "[ERROR] Watchdog timer expired at cycle %0d!", cycle_count);
        end
    end

    // -------------------------------------------------------------------------
    // Backpressure Mode Enumeration
    // -------------------------------------------------------------------------
    typedef enum int {
        BP_NONE            = 0, // Zero backpressure: full bandwidth streaming
        BP_SINK_PINGPONG   = 1, // Sink alternates ready/stall on consecutive cycles
        BP_SINK_HEAVY_90   = 2, // Sink applies heavy stall (~85% backpressure)
        BP_SINK_BURST      = 3, // Sink accepts in periodic bursts of 7 cycles
        BP_SRC_STARVE      = 4, // Source injects valid data sparsely (~20% duty)
        BP_SRC_BURST       = 5, // Source injects in bursts of 8 cycles
        BP_COMBINED_RANDOM = 6  // Simultaneous randomized source and sink handshakes
    } bp_mode_t;

    // Simulation Verification Counters
    integer total_mismatches = 0; // Cumulative error count
    integer total_verified   = 0; // Cumulative verified vector count

    // -------------------------------------------------------------------------
    // Task: run_test_segment
    // Executes a designated slice of test vectors [start_idx .. end_idx]
    // under a specific traffic/backpressure condition.
    // -------------------------------------------------------------------------
    task automatic run_test_segment(
        input string    test_name,
        input int       start_idx,
        input int       end_idx,
        input bp_mode_t mode
    );
        int sent;
        int recv;
        int count;
        int burst_timer_src;
        int burst_timer_snk;
        int seg_start_cycle;

        count           = end_idx - start_idx + 1;
        sent            = 0;
        recv            = 0;
        burst_timer_src = 0;
        burst_timer_snk = 0;
        seg_start_cycle = cycle_count;

        $display("-----------------------------------------------------------------");
        $display("[TEST] Starting %s: vectors [%0d .. %0d] (count = %0d)", test_name, start_idx, end_idx, count);

        fork
            // =================================================================
            // PRODUCER / SENDER PROCESS
            // =================================================================
            begin
                while (sent < count) begin
                    logic drive_val;
                    drive_val = 1'b1;

                    // Evaluate source valid drive decision according to mode
                    case (mode)
                        BP_NONE:            drive_val = 1'b1;
                        BP_SINK_PINGPONG:   drive_val = 1'b1;
                        BP_SINK_HEAVY_90:   drive_val = 1'b1;
                        BP_SINK_BURST:      drive_val = 1'b1;
                        BP_SRC_STARVE:      drive_val = (($urandom % 100) < 20);
                        BP_SRC_BURST: begin
                            burst_timer_src++;
                            drive_val = ((burst_timer_src % 25) < 8);
                        end
                        BP_COMBINED_RANDOM: drive_val = (($urandom % 100) < 50);
                    endcase

                    // Drive stimulus on negative clock edge to avoid setup race
                    @(negedge clk);
                    if (drive_val) begin
                        in_valid = 1'b1;
                        in_a     = vec_a[start_idx + sent];
                        in_b     = vec_b[start_idx + sent];
                        // Frame packets into 64-element blocks, or assert at segment end
                        in_last  = ((start_idx + sent) % 64 == 63) || (sent == count - 1);
                        
                        // Handshake completion: hold data until DUT asserts in_ready on posedge
                        while (1) begin
                            if (in_ready) begin
                                @(posedge clk);
                                sent++; // Transfer accepted
                                break;
                            end else begin
                                @(posedge clk);
                                @(negedge clk);
                            end
                        end
                    end else begin
                        // Idle cycle: deassert valid and drive unknown to expose illegal sampling
                        in_valid = 1'b0;
                        in_a     = 'x;
                        in_b     = 'x;
                        in_last  = 1'b0;
                        @(posedge clk);
                    end
                end

                // Cleanly deassert input interface after segment completion
                @(negedge clk);
                in_valid = 1'b0;
                in_last  = 1'b0;
                in_a     = 'x;
                in_b     = 'x;
            end

            // =================================================================
            // CONSUMER / RECEIVER PROCESS
            // =================================================================
            begin
                while (recv < count) begin
                    logic drive_rdy;
                    drive_rdy = 1'b1;

                    // Evaluate sink ready backpressure decision according to mode
                    case (mode)
                        BP_NONE:            drive_rdy = 1'b1;
                        BP_SINK_PINGPONG:   drive_rdy = (cycle_count % 2 == 0);
                        BP_SINK_HEAVY_90:   drive_rdy = (($urandom % 100) < 15);
                        BP_SINK_BURST: begin
                            burst_timer_snk++;
                            drive_rdy = ((burst_timer_snk % 30) < 7);
                        end
                        BP_SRC_STARVE:      drive_rdy = 1'b1;
                        BP_SRC_BURST:       drive_rdy = 1'b1;
                        BP_COMBINED_RANDOM: drive_rdy = (($urandom % 100) < 45);
                    endcase

                    @(negedge clk);
                    // Check if downstream is ready and DUT has valid output available
                    if (drive_rdy && out_valid) begin
                        logic [DATA_WIDTH-1:0] exp_val;
                        logic                  exp_last;

                        exp_val  = expected[start_idx + recv];
                        exp_last = ((start_idx + recv) % 64 == 63) || (recv == count - 1);

                        out_ready = 1'b1;
                        // Verify result against golden reference and check framing
                        if (out_data !== exp_val || out_last !== exp_last) begin
                            $display("[FAIL] idx %0d: expected=%03x (last=%b), got=%03x (last=%b)",
                                     start_idx + recv, exp_val, exp_last, out_data, out_last);
                            total_mismatches++;
                        end else begin
                            total_verified++;
                        end
                        @(posedge clk);
                        recv++; // Output transaction retired
                    end else begin
                        out_ready = drive_rdy;
                        @(posedge clk);
                    end
                end

                // Deassert out_ready upon completion of test segment
                @(negedge clk);
                out_ready = 1'b0;
            end
        join

        $display("[PASS] %s finished in %0d cycles.", test_name, cycle_count - seg_start_cycle);
    endtask

    // -------------------------------------------------------------------------
    // Main Test Execution Flow
    // -------------------------------------------------------------------------
    initial begin
        $display("=================================================================");
        $display("STARTING SIMULATION: tb_field_add (Clock: 450 MHz, Q = %0d)", Q);
        $display("=================================================================");

        // Asynchronous reset initialization sequence
        rst_n     = 0;
        in_valid  = 0;
        in_last   = 0;
        out_ready = 0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1; // Release reset
        repeat (5) @(posedge clk);

        // Run full spectrum of backpressure tests across all 7,724 vectors
        run_test_segment("Phase 0: BP_NONE (Full Throughput)",        0,    999,  BP_NONE);
        run_test_segment("Phase 1: BP_SINK_PINGPONG (Sink 50% Stall)", 1000, 1999, BP_SINK_PINGPONG);
        run_test_segment("Phase 2: BP_SINK_HEAVY_90 (Sink 85% Stall)", 2000, 2999, BP_SINK_HEAVY_90);
        run_test_segment("Phase 3: BP_SINK_BURST (Sink Bursty)",       3000, 3999, BP_SINK_BURST);
        run_test_segment("Phase 4: BP_SRC_STARVE (Source Starvation)", 4000, 4999, BP_SRC_STARVE);
        run_test_segment("Phase 5: BP_SRC_BURST (Source Bursty)",      5000, 5999, BP_SRC_BURST);
        run_test_segment("Phase 6: BP_COMBINED_RANDOM (Heavy Stress)", 6000, 7723, BP_COMBINED_RANDOM);

        repeat (20) @(posedge clk);

        // Print final simulation results summary
        $display("=================================================================");
        $display("SIMULATION SUMMARY: tb_field_add");
        $display("Total vectors verified : %0d / %0d", total_verified, TOTAL_VECTORS);
        $display("Total mismatches       : %0d", total_mismatches);
        $display("Total simulation cycles: %0d", cycle_count);
        $display("=================================================================");

        // Self-checking pass/fail verdict
        if (total_mismatches == 0 && total_verified == TOTAL_VECTORS) begin
            $display("[ALL TESTS PASSED SUCCESSFULLY]");
            $finish(0);
        end else begin
            $fatal(1, "[TESTBENCH FAILED WITH MISMATCHES]");
        end
    end

endmodule
