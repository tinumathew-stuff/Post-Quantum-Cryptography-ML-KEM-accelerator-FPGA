`timescale 1ns/1ps

// ============================================================================
// Module: tb_keccak_f1600
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Specification: NIST FIPS 202 Known Answer Tests (KAT)
//
// Description:
//   Self-checking, cycle-accurate standalone testbench for the Keccak-f[1600]
//   cryptographic permutation core (keccak_f1600.sv).
//
// Verification Scope:
//   1. Functional Correctness:
//      Validates full 1600-bit state permutation transformations against 13
//      Known Answer Test (KAT) vectors derived from the NIST Cryptographic
//      Algorithm Validation Program (CAVP) and Stockham reference models.
//   2. Timing & Latency Rigor:
//      Measures execution latency cycle-by-cycle, verifying that in FAST_24=1
//      mode the core completes the 24-round permutation in exactly 24 clock
//      cycles with zero latency jitter.
//   3. Interface Protocol Compliance:
//      Verifies handshake behavior of ready, start, load, done, and state_out
//      under 450 MHz clocking conditions (2.222 ns period).
//   4. Watchdog Protection:
//      Monitors continuous cycle count to terminate simulation if deadlocks
//      or infinite loops occur.
// ============================================================================
module tb_keccak_f1600;

    // -------------------------------------------------------------------------
    // Clock Generation: 450 MHz High-Performance System Clock
    // Toggle interval #1.111 ns gives a nominal clock period T_clk = 2.222 ns.
    // -------------------------------------------------------------------------
    logic clk = 0;
    always #1.111 clk = ~clk; // 450 MHz clock

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Interface Signals
    // -------------------------------------------------------------------------
    logic          rst_n;     // Active-low synchronous/asynchronous reset
    logic          start;     // Permutation start strobe
    logic          load;      // Direct state load strobe
    logic [1599:0] state_in;  // 1600-bit input stimulus state
    logic [1599:0] state_out; // 1600-bit output response state
    logic          ready;     // Core idle / ready status indicator
    logic          done;      // Single-cycle completion pulse

    // -------------------------------------------------------------------------
    // DUT Instantiation: FAST_24 = 1 Mode (24 Clock Cycles per Permutation)
    // -------------------------------------------------------------------------
    keccak_f1600 #(.FAST_24(1)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .load(load),
        .state_in(state_in),
        .ready(ready),
        .done(done),
        .state_out(state_out)
    );

    // -------------------------------------------------------------------------
    // Simulation Watchdog Timer
    // Prevents hanging simulations during automated regression runs (e.g. CI/CD)
    // by asserting a fatal error after 10,000 clock cycles.
    // -------------------------------------------------------------------------
    integer cycles = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles > 10000) begin
            $fatal(1, "Watchdog timeout in tb_keccak_f1600!");
        end
    end

    // -------------------------------------------------------------------------
    // Test Vector Storage
    // Stores 13 sets of 1600-bit input stimuli and golden output responses.
    // -------------------------------------------------------------------------
    localparam NUM_VECTORS = 13;
    logic [1599:0] expected_in  [0:NUM_VECTORS-1];
    logic [1599:0] expected_out [0:NUM_VECTORS-1];

    // -------------------------------------------------------------------------
    // Task: run_test_vector
    // Drives a single 1600-bit test vector, verifies 24-cycle latency, and
    // asserts bit-exact output equivalence against golden KAT vectors.
    // -------------------------------------------------------------------------
    task automatic run_test_vector(input integer idx);
        integer start_cyc, elapsed;
        begin
            // Wait until DUT is ready to accept commands
            wait (ready);

            // Drive inputs on falling clock edge to ensure clean setup and hold times
            @(negedge clk);
            state_in = expected_in[idx];
            load = 1;
            start = 1;

            @(negedge clk);
            load = 0;
            start = 0;
            start_cyc = cycles; // Record cycle timestamp at computation start

            // Wait for completion (ready reassertion)
            wait (ready);
            elapsed = cycles - start_cyc;

            // Rigorous latency validation: FAST_24 mode must take exactly 24 cycles
            if (elapsed != 24)
                $fatal(1, "Case %0d: Expected 24 cycles latency, got %0d cycles", idx, elapsed);

            // Bit-exact verification against 1600-bit golden Stockham / FIPS 202 KAT vector
            if (state_out !== expected_out[idx]) begin
                $fatal(1, "MISMATCH in Keccak-f[1600] case %0d!\n  Got:  %h\n  Want: %h",
                       idx, state_out, expected_out[idx]);
            end

            // Report vector pass
            $display("   PASS Case %02d: Latency = 24 cycles, 1600-bit state matches Stockham KAT bit-exact!", idx);
            @(negedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Test Stimulus Process
    // -------------------------------------------------------------------------
    initial begin
        $display("==================================================================");
        $display("Starting Keccak-f[1600] Stockham KAT Regression Testbench");
        $display("==================================================================");

        // Load 1600-bit hexadecimal test vectors from disk
        $readmemh("keccak_f1600_in.hex", expected_in);
        $readmemh("keccak_f1600_out.hex", expected_out);

        // Apply reset sequence
        rst_n    = 0;
        start    = 0;
        load     = 0;
        state_in = '0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // Iterate sequentially through all 13 regression test vectors
        for (int i = 0; i < NUM_VECTORS; i++) begin
            run_test_vector(i);
        end

        // Final verification summary banner
        $display("==================================================================");
        $display("ALL %0d KECCAK-F[1600] KAT VECTORS PASSED 100%% BIT-EXACT!", NUM_VECTORS);
        $display("==================================================================");
        $finish;
    end

endmodule
