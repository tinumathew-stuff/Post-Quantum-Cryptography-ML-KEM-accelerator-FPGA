`timescale 1ns/1ps

//==================================================================================================
// Module Name: tb_mlkem_hash_sampler
// Project:     ML-KEM High-Performance Kyber Accelerator (HPKA)
// Standards:   NIST FIPS 202 (SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions)
//              NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism / ML-KEM)
//
// Description:
//   Comprehensive, publication-grade testbench and verification suite for the unified
//   `mlkem_hash_sampler` subsystem. The DUT combines Keccak-f[1600] permutation acceleration,
//   SHA3-256, SHA3-512, and SHAKE extendable-output functions (XOF) with dedicated high-throughput
//   rejection sampling hardware for:
//     1. Matrix A Uniform Sampling (SampleNTT via SHAKE-128):
//        Samples public polynomial matrices A in R_q^(k x k) modulo q = 3329 from seed rho.
//        Supports both standard matrix A and transposed matrix A^T across ML-KEM-512 (k=2),
//        ML-KEM-768 (k=3), and ML-KEM-1024 (k=4).
//     2. Centered Binomial Distribution Noise Sampling (SamplePolyCBD_eta via SHAKE-256):
//        Generates small secret and error polynomial vectors s, e, r, e1, e2:
//        - CBD2 (eta=2): 64 bytes -> 128 coefficients (4 bits/coeff) for ML-KEM-512/768/1024.
//        - CBD3 (eta=3): 96 bytes -> 128 coefficients (6 bits/coeff) for ML-KEM-512/768.
//     3. Classical Hashing:
//        NIST bit-exact SHA3-256, SHA3-512, and SHAKE-256 digests over arbitrary message lengths.
//
// High-Throughput 48-bit Streaming Output Architecture:
//   - Delivers up to 4 12-bit polynomial coefficients per clock cycle (out_data[47:0], out_count in [1..4])
//     directly into the accelerator's NTT arithmetic core or polynomial memory banks.
//   - Polynomial boundaries are flagged via `out_last` (asserted every 256 coefficients) and tagged
//     with `out_poly_index` (0 to k*k-1 or 0 to k-1).
//   - In Hash/SHAKE modes, out_data[7:0] delivers 1 byte per cycle with out_count = 1.
//
// Advanced Verification Features:
//   - Dynamic Pseudo-Random Backpressure: Emulates downstream memory/pipeline stalls via a 16-bit
//     linear feedback shift register (LFSR) combined with modulo cycle choking.
//   - Backpressure Stability Assertion: Rigorously verifies that during stall events (out_valid && !out_ready),
//     all output data, counts, last flags, and polynomial indices remain strictly invariant.
//   - Bit-Exact NIST KAT Comparison: Golden reference vectors generated from C reference code
//     loaded via `$readmemh` with zero-tolerance mismatch detection ($fatal).
//   - Two-Level Watchdog Timers: Per-case watchdog (60,000 cycles) and global watchdog (2,000,000 cycles)
//     to prevent undetected deadlocks or state machine livelocks.
//==================================================================================================

module tb_mlkem_hash_sampler;

    //----------------------------------------------------------------------------------------------
    // Clock and Reset Signals
    //----------------------------------------------------------------------------------------------
    logic clk = 0;
    always #1.111 clk = ~clk; // 450 MHz clock generation (period = 2.222 ns)

    logic rst_n = 0;            // Active-low asynchronous/synchronous system reset

    //----------------------------------------------------------------------------------------------
    // Command Control and Configuration Interface
    //----------------------------------------------------------------------------------------------
    logic         cmd_valid = 0; // Command strobe to initiate sampling or hashing
    logic         cmd_ready;     // DUT ready to accept next command
    logic [2:0]   cmd_mode = 0;  // Operating Mode:
                                 //   0: SHA3-256
                                 //   1: SHA3-512
                                 //   2: Matrix A Rejection Sampling (SHAKE-128)
                                 //   3: Vector CBD Noise Sampling (SHAKE-256)
                                 //   4: SHAKE-256 XOF Hashing
    logic [2:0]   cmd_k = 0;     // ML-KEM Security Parameter k (2: 512, 3: 768, 4: 1024)
    logic [255:0] cmd_seed = 0;  // 256-bit public seed (rho for Matrix A, sigma for CBD)
    logic         cmd_transpose = 0; // Transpose flag: 0 for Matrix A, 1 for Matrix A^T
    logic         cmd_eta3 = 0;      // CBD Parameter: 0 for eta=2 (CBD2), 1 for eta=3 (CBD3)
    logic [7:0]   cmd_nonce = 8'd4;  // Domain separation nonce byte for CBD sampling

    //----------------------------------------------------------------------------------------------
    // Streaming Input Message Interface (Hash & SHAKE modes)
    //----------------------------------------------------------------------------------------------
    logic       in_valid = 0;   // Byte stream input valid
    logic       in_ready;       // DUT ready to accept input byte
    logic [7:0] in_data = 0;    // Input byte payload
    logic       in_last = 0;    // Indicates last byte of input message stream
    logic       in_keep = 0;    // Byte qualifier strobe (0 for zero-length / pad-only messages)

    //----------------------------------------------------------------------------------------------
    // Streaming Output Interface (Coefficients & Hash Digests)
    //----------------------------------------------------------------------------------------------
    logic        out_valid;      // Stream output valid strobe
    logic        out_ready = 1;  // Downstream consumer ready / backpressure control
    logic [47:0] out_data;       // 48-bit wide output bus:
                                 //   - Sampler modes: packed {coeff3, coeff2, coeff1, coeff0} (4 x 12-bit)
                                 //   - Hash modes:    out_data[7:0] contains output digest byte
    logic [2:0]  out_count;      // Number of valid items in current beat (1 to 4 for coeffs; 1 for hash)
    logic        out_last;       // Sampler: indicates end of 256-coeff polynomial; Hash: end of digest
    logic [3:0]  out_poly_index; // Current polynomial index being emitted (0 to k*k-1 or 0 to k-1)
    logic        cmd_done;       // Asserted when the entire command operation is completed

    //----------------------------------------------------------------------------------------------
    // Testbench Control, Emulation LFSR, and KAT Memories
    //----------------------------------------------------------------------------------------------
    logic        use_backpressure = 0;     // Test configuration flag to enable dynamic stalls
    logic [15:0] lfsr = 16'hace1;          // 16-bit Galois/Fibonacci LFSR for pseudo-random backpressure
    integer      clock_count = 0;          // Global simulation cycle counter
    logic [11:0] expected [0:4095];        // Precomputed golden reference memory (up to 4096 coeffs)
    logic [7:0]  reject_seed_mem [0:31];   // Seed memory for extreme edge-case rejection testing

    //----------------------------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    //----------------------------------------------------------------------------------------------
    mlkem_hash_sampler dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .cmd_valid      (cmd_valid),
        .cmd_ready      (cmd_ready),
        .cmd_mode       (cmd_mode),
        .cmd_k          (cmd_k),
        .cmd_seed       (cmd_seed),
        .cmd_transpose  (cmd_transpose),
        .cmd_eta3       (cmd_eta3),
        .cmd_nonce      (cmd_nonce),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_data        (in_data),
        .in_last        (in_last),
        .in_keep        (in_keep),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .mat_out_ready  (out_ready),
        .vec_out_ready  (out_ready),
        .out_data       (out_data),
        .out_count      (out_count),
        .out_last       (out_last),
        .out_poly_index (out_poly_index),
        .cmd_done       (cmd_done)
    );

    //----------------------------------------------------------------------------------------------
    // Global Watchdog and Cycle Counter
    // Guards against deadlocks, unhandled states, or dropped handshake completions.
    //----------------------------------------------------------------------------------------------
    always @(posedge clk) begin
        clock_count <= clock_count + 1;
        if (clock_count > 2000000) begin
            $fatal(1, "Global timeout watchdog triggered in tb_mlkem_hash_sampler!");
        end
    end

    //----------------------------------------------------------------------------------------------
    // Pseudo-Random Backpressure Generator
    // Evaluates a 16-bit primitive polynomial x^16 + x^14 + x^13 + x^11 + 1 on falling clock edges
    // to dynamically throttle out_ready and thoroughly test DUT skid buffers and stall pipelines.
    //----------------------------------------------------------------------------------------------
    always @(negedge clk) begin
        if (rst_n) begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            out_ready <= !use_backpressure ||
                         ((lfsr[3:0] < 4'd10) && ((clock_count % 211) < 170));
        end
    end

    //==============================================================================================
    // Verification Task: run_case
    // Executes an individual verification test scenario:
    //   - Formulates KAT file name and loads expected reference vectors.
    //   - Dispatches command and streams message inputs (for hash modes).
    //   - Emulates receiver consumption with optional pseudo-random backpressure stalls.
    //   - Asserts backpressure stability and validates bit-exact coefficient/digest correctness.
    //==============================================================================================
    task automatic run_case(
        input logic [2:0] mode,         // 0: SHA3-256, 1: SHA3-512, 2: Matrix, 3: Vector, 4: SHAKE-256
        input integer     k,            // Security level parameter: 2, 3, or 4
        input bit         transpose,    // 1: Transposed Matrix A^T, 0: Normal Matrix A
        input bit         eta3,         // 1: CBD3 (eta=3), 0: CBD2 (eta=2)
        input bit         stalled,      // 1: Enable dynamic LFSR backpressure stalls
        input integer     msg_len,      // Message length in bytes for hash modes
        input bit         is_reject     // 1: Load special adversarial seed with high rejection rate
    );
        string   path;
        integer  total, seen, start_clock, watchdog;
        logic    held;
        logic [47:0] held_data;
        logic [2:0]  held_count;
        logic        held_last;
        logic [3:0]  held_poly;
        begin
            // Determine expected vector file path and total expected output elements
            if (mode == 0) begin
                path = $sformatf("hash256_len%0d.hex", msg_len);
                total = 32;             // 32-byte digest
            end else if (mode == 1) begin
                path = $sformatf("hash512_len%0d.hex", msg_len);
                total = 64;             // 64-byte digest
            end else if (mode == 4) begin
                path = $sformatf("shake256_len%0d.hex", msg_len);
                total = 32;             // 32-byte squeezed output
            end else if (mode == 2) begin
                if (is_reject) path = "reject_matrix_k2.hex";
                else path = $sformatf("matrix_k%0d_t%0d.hex", k, transpose);
                total = k * k * 256;    // k x k polynomials of 256 coefficients each
            end else begin
                if (cmd_nonce == 8'd255)
                    path = $sformatf("vector_k4_eta%0d_n255.hex", eta3 ? 3 : 2);
                else
                    path = $sformatf("vector_k%0d_eta%0d.hex", k, eta3 ? 3 : 2);
                total = k * 256;        // k polynomials of 256 coefficients each
            end

            // Load precomputed bit-exact golden reference file
            $readmemh(path, expected);

            // Wait for DUT command interface readiness
            @(negedge clk);
            if (!cmd_ready) $fatal(1, "Command interface not ready");

            // Override seed for specialized rejection sampling test vectors
            if (is_reject) begin
                $readmemh("reject_seed.hex", reject_seed_mem);
                for (integer i=0; i<32; i++) cmd_seed[i*8 +: 8] = reject_seed_mem[i];
            end

            // Issue sampling / hash command
            cmd_mode = mode;
            cmd_k = 3'(k);
            cmd_transpose = transpose;
            cmd_eta3 = eta3;
            cmd_valid = 1;
            use_backpressure = stalled;
            @(negedge clk);
            cmd_valid = 0;

            seen = 0;
            watchdog = 0;
            held = 0;
            start_clock = clock_count;

            // Stream input message bytes for Hash/SHAKE modes
            if (mode < 2 || mode == 4) begin
                if (msg_len == 0) begin
                    // Zero-length message test case (pad-only block absorption)
                    @(negedge clk);
                    in_valid = 1; in_keep = 0; in_last = 1;
                    do @(posedge clk); while (!in_ready);
                    @(negedge clk);
                    in_valid = 0;
                end else begin
                    // Stream msg_len bytes derived from repeating seed pattern
                    for (integer m = 0; m < msg_len; m = m + 1) begin
                        @(negedge clk);
                        in_valid = 1; in_keep = 1;
                        in_data = cmd_seed[(m % 32)*8 +: 8];
                        in_last = (m == msg_len - 1);
                        do @(posedge clk); while (!in_ready);
                        @(negedge clk);
                        in_valid = 0;
                    end
                end
            end

            // Consume and verify outputs until command completion
            while (cmd_done !== 1'b1) begin
                @(posedge clk);
                watchdog = watchdog + 1;
                if (watchdog > 60000)
                    $fatal(1, "Timeout in case mode=%0d k=%0d transpose=%0d len=%0d", mode, k, transpose, msg_len);

                // Protocol Assertion: Verify output bus immutability during downstream backpressure stalls
                if (held && (!out_valid || out_data !== held_data ||
                             out_count !== held_count || out_last !== held_last ||
                             out_poly_index !== held_poly)) begin
                    $display("Backpressure violation details:");
                    $display("  out_valid:      %b (held was 1)", out_valid);
                    $display("  out_data:       got %h, held %h", out_data, held_data);
                    $display("  out_count:      got %0d, held %0d", out_count, held_count);
                    $display("  out_last:       got %b, held %b", out_last, held_last);
                    $display("  out_poly_index: got %0d, held %0d", out_poly_index, held_poly);
                    $fatal(1, "Output changed during backpressure stall!");
                end

                // Record state when DUT is stalled waiting for consumer ready
                held = out_valid && !out_ready;
                if (held) begin
                    held_data = out_data;
                    held_count = out_count;
                    held_last = out_last;
                    held_poly = out_poly_index;
                end

                // Output Beat Handshake: out_valid && out_ready
                if (out_valid && out_ready) begin
                    if (mode < 2 || mode == 4) begin
                        // Hash/SHAKE Verification: exactly 1 byte per beat on out_data[7:0]
                        if (out_count !== 3'd1 || out_data[7:0] !== expected[seen][7:0]) begin
                            $fatal(1, "Hash mismatch: mode=%0d byte=%0d got=%02x exp=%02x",
                                   mode, seen, out_data[7:0], expected[seen][7:0]);
                        end
                    end else begin
                        // Matrix or Vector CBD Sampling Verification: up to 4 12-bit coefficients per beat
                        if (out_count == 3'd0 || out_count > 3'd4)
                            $fatal(1, "Invalid out_count: %0d", out_count);

                        // Verify polynomial index tracking: must match floor(seen / 256)
                        if (out_poly_index !== 4'(seen / 256))
                            $fatal(1, "Poly index mismatch: got=%0d exp=%0d", out_poly_index, seen/256);

                        // Compare each valid coefficient against golden KAT reference
                        for (integer lane = 0; lane < out_count; lane = lane + 1) begin
                            logic [11:0] coeff_got;
                            coeff_got = out_data[lane*12 +: 12];
                            if (coeff_got !== expected[seen + lane]) begin
                                $fatal(1, "Coeff mismatch: mode=%0d k=%0d idx=%0d lane=%0d got=%03x exp=%03x",
                                       mode, k, seen + lane, lane, coeff_got, expected[seen + lane]);
                            end
                        end
                    end

                    // Check last marker assertion semantics
                    if (out_last !== ((mode < 2 || mode == 4) ? (seen + out_count == total) :
                                      ((seen + out_count) % 256 == 0))) begin
                        $fatal(1, "Last marker mismatch at index %0d (seen=%0d, count=%0d, total=%0d)",
                               seen, seen, out_count, total);
                    end

                    seen = seen + out_count;
                    if (seen > total) $fatal(1, "Too many outputs emitted: %0d > %0d", seen, total);
                end
            end

            // Validate that the exact expected number of elements were produced
            if (seen != total)
                $fatal(1, "Missing outputs: mode=%0d k=%0d got=%0d exp=%0d", mode, k, seen, total);

            $display("   PASS: mode=%0d k=%0d transpose=%0d eta3=%0d stalled=%0d len=%0d total=%0d in %0d cycles (Bit-Exact KAT!)",
                     mode, k, transpose, eta3, stalled, msg_len, total, clock_count - start_clock);
            @(negedge clk);
        end
    endtask

    //==============================================================================================
    // Main Test Stimulus Process
    // Sequentially tests all cryptographic hashing, matrix sampling, and CBD vector configurations.
    //==============================================================================================
    initial begin
        $display("==================================================================");
        $display("Starting Stockham KAT Regression for mlkem_hash_sampler (48-bit)");
        $display("==================================================================");

        // Standard seed: repeat {0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef} 4 times
        for (integer i=0; i<32; i=i+1)
            cmd_seed[i*8 +: 8] = 8'({8'h01,8'h23,8'h45,8'h67,8'h89,8'hab,8'hcd,8'hef} >> ((7-(i%8))*8));

        // Power-On Reset Sequence
        rst_n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        //------------------------------------------------------------------------------------------
        // 1. SHA3-256 Tests
        // Evaluates message lengths spanning 0 bytes (pad only), 3 bytes, 32 bytes (KeyGen/Encaps),
        // 71 bytes (with backpressure stalls), and 136 bytes (full rate block boundary).
        //------------------------------------------------------------------------------------------
        $display("\n--- 1. Testing SHA3-256 KATs ---");
        run_case(0, 2, 0, 0, 0, 0, 0);
        run_case(0, 2, 0, 0, 0, 3, 0);
        run_case(0, 2, 0, 0, 0, 32, 0);
        run_case(0, 2, 0, 0, 1, 71, 0);
        run_case(0, 2, 0, 0, 0, 136, 0);

        //------------------------------------------------------------------------------------------
        // 2. SHA3-512 Tests
        // Verifies 512-bit digest generation for FO transform (m || H(pk)) hashing across various lengths.
        //------------------------------------------------------------------------------------------
        $display("\n--- 2. Testing SHA3-512 KATs ---");
        run_case(1, 2, 0, 0, 0, 0, 0);
        run_case(1, 2, 0, 0, 0, 32, 0);
        run_case(1, 2, 0, 0, 1, 72, 0);
        run_case(1, 2, 0, 0, 0, 136, 0);

        //------------------------------------------------------------------------------------------
        // 3. SHAKE-256 Tests
        // Verifies 256-bit XOF squeeze output for 32-byte and 136-byte inputs.
        //------------------------------------------------------------------------------------------
        $display("\n--- 3. Testing SHAKE-256 KATs ---");
        run_case(4, 2, 0, 0, 0, 32, 0);
        run_case(4, 2, 0, 0, 1, 136, 0);

        //------------------------------------------------------------------------------------------
        // 4. Matrix A Rejection Sampling Tests (k=2, 3, 4, transpose=0, 1)
        // Verifies SampleNTT using SHAKE-128 across all security parameters, with and without stalls:
        //   - k=2 (ML-KEM-512):  4 polynomials  (1024 coefficients)
        //   - k=3 (ML-KEM-768):  9 polynomials  (2304 coefficients)
        //   - k=4 (ML-KEM-1024): 16 polynomials (4096 coefficients)
        //------------------------------------------------------------------------------------------
        $display("\n--- 4. Testing Matrix A Rejection Sampling KATs (4-way) ---");
        for (integer k = 2; k <= 4; k = k + 1) begin
            for (integer t = 0; t < 2; t = t + 1) begin
                run_case(2, k, 1'(t), 0, 0, 0, 0);
                run_case(2, k, 1'(t), 0, 1, 0, 0); // with dynamic stall backpressure
            end
        end

        //------------------------------------------------------------------------------------------
        // 5. CBD2 and CBD3 Noise Sampling Tests
        // Verifies Centered Binomial Distribution error vector sampling:
        //   - CBD2 (eta=2) for k=2, 3, 4 (with and without backpressure stalls)
        //   - CBD3 (eta=3) for k=2, 3    (with and without backpressure stalls)
        //------------------------------------------------------------------------------------------
        $display("\n--- 5. Testing CBD2 and CBD3 Noise Sampling KATs (4-way) ---");
        for (integer k = 2; k <= 4; k = k + 1) begin
            run_case(3, k, 0, 0, 0, 0, 0); // eta=2
            run_case(3, k, 0, 0, 1, 0, 0); // eta=2 with stall
            if (k <= 3) begin
                run_case(3, k, 0, 1, 0, 0, 0); // eta=3
                run_case(3, k, 0, 1, 1, 0, 0); // eta=3 with stall
            end
        end

        //------------------------------------------------------------------------------------------
        // 6. Edge Case Rejection Sampling
        // Stress tests DUT rejection pipeline with a specially crafted seed yielding dense rejects.
        //------------------------------------------------------------------------------------------
        $display("\n--- 6. Testing Rejection Edge Case KAT ---");
        run_case(2, 2, 0, 0, 0, 0, 1);

        $display("\n==================================================================");
        $display("ALL HASH & SAMPLER STOCKHAM KATS PASSED 100%% BIT-EXACT!");
        $display("==================================================================");
        $finish;
    end
endmodule
