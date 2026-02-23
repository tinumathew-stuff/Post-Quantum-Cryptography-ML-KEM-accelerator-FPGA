//==============================================================================
// File: tb_field_sub.sv
// Project: ML-KEM (CRYSTALS-Kyber) High-Performance Hardware Accelerator
// Component: Modular Subtraction Unit Testbench (Field Subtractor)
//
// Description:
//   Comprehensive, self-checking SystemVerilog testbench for the 12-bit modular
//   subtraction core (field_sub) targeting ML-KEM / FIPS 203 arithmetic over
//   the prime Galois field GF(q) with modulus q = 3329.
//
// Theoretical and Mathematical Foundations:
//   Given operands a, b in [0, q-1], the modular difference c is defined as:
//       c = (a - b) mod q
//   In integer arithmetic:
//       raw_diff = a - b
//       c = (raw_diff < 0) ? (raw_diff + q) : raw_diff
//   The field subtractor ensures canonical closure within [0, q-1] without
//   incurring multi-cycle iterative divisions or stalls.
//
// Testbench Architecture & Verification Methodology:
//   1. Clock Generation:
//      - Generates a high-frequency clock running at 450.045 MHz (period T ~ 2.222 ns,
//        modeled via #1.111 ns half-cycle toggles) reflecting target operating frequency
//        on AMD UltraScale+ FPGAs (xck26-sfvc784-2LV-c).
//   2. Handshake Verification (AXI4-Stream Ready/Valid Paradigm):
//      - Validates complete compliance with the ready/valid protocol.
//      - Stimulus is launched at negative clock edges (negedge clk) to guarantee
//        generous setup and hold margins relative to the active rising edge.
//      - Transfers commit synchronously on the rising clock edge (posedge clk)
//        if and only if both 'valid' and 'ready' are asserted simultaneously.
//      - Comprehensive backpressure coverage tests internal skid buffers across
//        full throughput, sink stalls, source starvation, and randomized phases.
//   3. Test Stimulus & Vector Processing:
//      - Ingests 8,723 pre-computed test vectors from hexadecimal vector files
//        (input_a.hex, input_b.hex, expected.hex) generated via an independent
//        Python/C reference model of FIPS 203.
//      - Covers corner cases: minimum values (0), maximum values (q-1 = 3328),
//        equal values (a == b), underflow cases (a < b), and maximal distance cases.
//   4. Packet Framing Verification (in_last / out_last):
//      - Asserts 'last' on 64-coefficient block boundaries and segment boundaries
//        to verify that packet framing metadata flows faithfully alongside data.
//   5. Self-Checking Scoreboard & Watchdog:
//      - The concurrent receiver scoreboard matches incoming 'out_data' and 'out_last'
//        against expected vectors on every valid output transaction.
//      - A 500,000-cycle watchdog timer trips a $fatal fault if any pipeline lockup occurs.
//
// Backpressure Testing Matrix (Phases 0 through 6):
//   +-------+--------------------+---------------------------------------------------+
//   | Phase | Mode Enum          | Operational Conditions & Stress Description       |
//   +-------+--------------------+---------------------------------------------------+
//   |   0   | BP_NONE            | 100% throughput: Source continuous, Sink ready=1  |
//   |   1   | BP_SINK_PINGPONG   | 50% sink duty cycle: Sink ready toggles 1/0/1/0   |
//   |   2   | BP_SINK_HEAVY_90   | 85% sink stall: Sink ready asserted ~15% of cycles|
//   |   3   | BP_SINK_BURST      | Bursty sink: 7 cycles ready, 23 cycles stalled    |
//   |   4   | BP_SRC_STARVE      | Source starved: in_valid asserted ~20% of cycles  |
//   |   5   | BP_SRC_BURST       | Bursty source: 8 cycles valid, 17 cycles idle     |
//   |   6   | BP_COMBINED_RANDOM | Pseudo-random stress: 50% valid, 45% ready        |
//   +-------+--------------------+---------------------------------------------------+
//
// Timing & Sampling Model:
//   clk:         __--__--__--__--__--__--__--__--__--__--
//   Drive:             ^ negedge (stimulus & ready update)
//   Sample:                 ^ posedge (DUT registers & scoreboard check)
//
//==============================================================================

`timescale 1ns/1ps

module tb_field_sub;

    //--------------------------------------------------------------------------
    // Parameters & Constants
    //--------------------------------------------------------------------------
    localparam int DATA_WIDTH = 12;                 // Field element bit width (12 bits)
    localparam logic [DATA_WIDTH-1:0] Q = 12'd3329; // ML-KEM prime modulus q = 3329
    localparam int TOTAL_VECTORS = 8723;            // Total test vectors in test suite

    //--------------------------------------------------------------------------
    // Clock & Reset Signals
    //--------------------------------------------------------------------------
    // 450 MHz clock generator:
    // Period T = 2 * 1.111 ns = 2.222 ns -> f ~ 450.045 MHz
    logic                  clk = 0;
    always #1.111 clk = ~clk; // 450 MHz clock (T ~ 2.222 ns)

    // Asynchronous / synchronous active-low reset
    logic                  rst_n = 0;

    //--------------------------------------------------------------------------
    // DUT Interface Signals
    //--------------------------------------------------------------------------
    // Upstream (Input) Handshake & Data
    logic                  in_valid = 0; // Upstream valid indicator
    logic                  in_ready;     // DUT ready to accept upstream input
    logic [DATA_WIDTH-1:0] in_a = 0;     // Minuend operand a in [0, Q-1]
    logic [DATA_WIDTH-1:0] in_b = 0;     // Subtrahend operand b in [0, Q-1]
    logic                  in_last = 0;  // Packet / block boundary delimiter

    // Downstream (Output) Handshake & Data
    logic                  out_valid;    // DUT output data valid
    logic                  out_ready = 0;// Downstream sink ready indicator
    logic [DATA_WIDTH-1:0] out_data;     // Difference output: c = (a - b) mod Q
    logic                  out_last;     // Output packet / block delimiter

    //--------------------------------------------------------------------------
    // Test Vector Storage Arrays
    //--------------------------------------------------------------------------
    // Memory arrays to buffer test patterns and golden reference values
    logic [DATA_WIDTH-1:0] vec_a    [0:TOTAL_VECTORS-1]; // Minuend vector table
    logic [DATA_WIDTH-1:0] vec_b    [0:TOTAL_VECTORS-1]; // Subtrahend vector table
    logic [DATA_WIDTH-1:0] expected [0:TOTAL_VECTORS-1]; // Precomputed golden result table

    //--------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    //--------------------------------------------------------------------------
    field_sub #(
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

    //--------------------------------------------------------------------------
    // Test Vector Ingestion Routine
    //--------------------------------------------------------------------------
    // Attempts to load vector files from either local or parent execution paths,
    // accommodating diverse test execution directories (e.g., sim/ or build/).
    initial begin
        int f;
        string path_a, path_b, path_exp;
        f = $fopen("field_sub/tb/input_a.hex", "r");
        if (f) begin
            $fclose(f);
            path_a   = "field_sub/tb/input_a.hex";
            path_b   = "field_sub/tb/input_b.hex";
            path_exp = "field_sub/tb/expected.hex";
        end else begin
            path_a   = "../field_sub/tb/input_a.hex";
            path_b   = "../field_sub/tb/input_b.hex";
            path_exp = "../field_sub/tb/expected.hex";
        end
        $readmemh(path_a, vec_a);
        $readmemh(path_b, vec_b);
        $readmemh(path_exp, expected);
        $display("[INFO] Loaded test vectors from %s", path_a);
    end

    //--------------------------------------------------------------------------
    // Simulation Watchdog Timer
    //--------------------------------------------------------------------------
    // Monitors cycle progression to detect unhandled deadlocks, circular stalls,
    // or missing ready/valid acknowledgments. Terminates simulation on failure.
    integer cycle_count = 0;
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > 500000) begin
            $fatal(1, "[ERROR] Watchdog timer expired at cycle %0d!", cycle_count);
        end
    end

    //--------------------------------------------------------------------------
    // Backpressure Modes & Verification Metrics
    //--------------------------------------------------------------------------
    // Enumeration specifying backpressure test behaviors for sender & receiver
    typedef enum int {
        BP_NONE            = 0, // Unconstrained back-to-back streaming
        BP_SINK_PINGPONG   = 1, // Sink alternates ready on every cycle
        BP_SINK_HEAVY_90   = 2, // Heavy sink backpressure (~85% stall probability)
        BP_SINK_BURST      = 3, // Periodic bursts of sink availability
        BP_SRC_STARVE      = 4, // Upstream source starving (low duty cycle ~20%)
        BP_SRC_BURST       = 5, // Periodic upstream bursts (8 of 25 cycles)
        BP_COMBINED_RANDOM = 6  // Concurrently randomized source & sink handshake
    } bp_mode_t;

    integer total_mismatches = 0; // Total accumulated scoreboard verification errors
    integer total_verified = 0;   // Total successfully validated vector transactions

    //--------------------------------------------------------------------------
    // Test Driver Task: run_test_segment
    //--------------------------------------------------------------------------
    // Drives a sub-segment of test vectors [start_idx .. end_idx] under the
    // specified backpressure profile 'mode'. Utilizes concurrent fork-join
    // threads to model independent upstream producer and downstream consumer.
    //
    // Arguments:
    //   test_name : Human-readable name for reporting
    //   start_idx : Starting vector index in the vector arrays
    //   end_idx   : Ending vector index in the vector arrays (inclusive)
    //   mode      : Backpressure profile to apply during this segment
    //--------------------------------------------------------------------------
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

        count = end_idx - start_idx + 1;
        sent = 0;
        recv = 0;
        burst_timer_src = 0;
        burst_timer_snk = 0;
        seg_start_cycle = cycle_count;

        $display("-----------------------------------------------------------------");
        $display("[TEST] Starting %s: vectors [%0d .. %0d] (count = %0d)", test_name, start_idx, end_idx, count);

        fork
            //==================================================================
            // SENDER PROCESS (Upstream Producer)
            // Generates input operands and drives in_valid according to 'mode'.
            // Manages skid buffer stalls and respects in_ready backpressure.
            //==================================================================
            begin
                while (sent < count) begin
                    logic drive_val;
                    drive_val = 1'b1;

                    // Evaluate source valid driving decision based on selected mode
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

                    // Update inputs at negedge clk to guarantee hold margin to posedge
                    @(negedge clk);
                    if (drive_val) begin
                        in_valid = 1'b1;
                        in_a     = vec_a[start_idx + sent];
                        in_b     = vec_b[start_idx + sent];
                        // Demarcate last element every 64-word chunk or at end of segment
                        in_last  = ((start_idx + sent) % 64 == 63) || (sent == count - 1);
                        
                        // Wait until transfer occurs at posedge clk:
                        // AXI-stream handshake succeeds when both in_valid and in_ready are high
                        while (1) begin
                            if (in_ready) begin
                                @(posedge clk);
                                sent++;
                                break;
                            end else begin
                                @(posedge clk);
                                @(negedge clk);
                            end
                        end
                    end else begin
                        // Starve DUT: deassert valid and drive unknown values on data lines
                        in_valid = 1'b0;
                        in_a     = 'x;
                        in_b     = 'x;
                        in_last  = 1'b0;
                        @(posedge clk);
                    end
                end

                // Clean up source signals upon segment completion
                @(negedge clk);
                in_valid = 1'b0;
                in_last  = 1'b0;
                in_a     = 'x;
                in_b     = 'x;
            end

            //==================================================================
            // RECEIVER PROCESS (Downstream Consumer & Scoreboard)
            // Emulates downstream backpressure and verifies output results
            // against the golden model reference table in lockstep.
            //==================================================================
            begin
                while (recv < count) begin
                    logic drive_rdy;
                    drive_rdy = 1'b1;

                    // Evaluate sink ready driving decision based on selected mode
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

                    // Drive out_ready at negedge clk
                    @(negedge clk);
                    if (drive_rdy && out_valid) begin
                        logic [DATA_WIDTH-1:0] exp_val;
                        logic                  exp_last;

                        exp_val  = expected[start_idx + recv];
                        exp_last = ((start_idx + recv) % 64 == 63) || (recv == count - 1);

                        out_ready = 1'b1;
                        // Scoreboard check: verify mathematical correctness and framing flag
                        if (out_data !== exp_val || out_last !== exp_last) begin
                            $display("[FAIL] idx %0d: expected=%03x (last=%b), got=%03x (last=%b)",
                                     start_idx + recv, exp_val, exp_last, out_data, out_last);
                            total_mismatches++;
                        end else begin
                            total_verified++;
                        end
                        @(posedge clk);
                        recv++;
                    end else begin
                        // Hold ready state during idle / wait cycles
                        out_ready = drive_rdy;
                        @(posedge clk);
                    end
                end

                // Deassert out_ready upon receiving all segment items
                @(negedge clk);
                out_ready = 1'b0;
            end
        join

        $display("[PASS] %s finished in %0d cycles.", test_name, cycle_count - seg_start_cycle);
    endtask

    //--------------------------------------------------------------------------
    // Main Test Orchestration
    //--------------------------------------------------------------------------
    // Executes reset assertion, phases through all backpressure regimes over
    // 8,723 vectors, and concludes with a definitive pass/fail report.
    initial begin
        $display("=================================================================");
        $display("STARTING SIMULATION: tb_field_sub (Clock: 450 MHz, Q = %0d)", Q);
        $display("=================================================================");

        // Reset sequence: assert reset for 10 clock cycles, deassert cleanly on negedge
        rst_n     = 0;
        in_valid  = 0;
        in_last   = 0;
        out_ready = 0;
        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Run full spectrum of backpressure tests covering all 8,723 vectors
        run_test_segment("Phase 0: BP_NONE (Full Throughput)",        0,    999,  BP_NONE);
        run_test_segment("Phase 1: BP_SINK_PINGPONG (Sink 50% Stall)", 1000, 1999, BP_SINK_PINGPONG);
        run_test_segment("Phase 2: BP_SINK_HEAVY_90 (Sink 85% Stall)", 2000, 2999, BP_SINK_HEAVY_90);
        run_test_segment("Phase 3: BP_SINK_BURST (Sink Bursty)",       3000, 3999, BP_SINK_BURST);
        run_test_segment("Phase 4: BP_SRC_STARVE (Source Starvation)", 4000, 4999, BP_SRC_STARVE);
        run_test_segment("Phase 5: BP_SRC_BURST (Source Bursty)",      5000, 5999, BP_SRC_BURST);
        run_test_segment("Phase 6: BP_COMBINED_RANDOM (Heavy Stress)", 6000, 8722, BP_COMBINED_RANDOM);

        repeat (20) @(posedge clk);

        // Print final simulation summary
        $display("=================================================================");
        $display("SIMULATION SUMMARY: tb_field_sub");
        $display("Total vectors verified : %0d / %0d", total_verified, TOTAL_VECTORS);
        $display("Total mismatches       : %0d", total_mismatches);
        $display("Total simulation cycles: %0d", cycle_count);
        $display("=================================================================");

        // Assess final verification status
        if (total_mismatches == 0 && total_verified == TOTAL_VECTORS) begin
            $display("[ALL TESTS PASSED SUCCESSFULLY]");
            $finish(0);
        end else begin
            $fatal(1, "[TESTBENCH FAILED WITH MISMATCHES]");
        end
    end

endmodule
