`timescale 1ns/1ps

// =============================================================================
// Module Name: tb_keygen_768
// Project:     ML-KEM Hardware Accelerator (FIPS 203 Post-Quantum Cryptography)
// Standard:    ML-KEM-768 (Category 3, k = 3)
// Description: Standalone KeyGen testbench for ML-KEM-768.
// =============================================================================

module tb_keygen_768;

    // Parameters
    localparam logic [2:0] K_PARAM    = 3'd3;
    localparam int         EK_LEN     = 1184;
    localparam int         DK_LEN     = 2400;
    localparam string      MODE_NAME  = "ML-KEM-768";
    localparam int         MAX_CYCLES = 2500;

    // Clock Generation (450 MHz, T = 2.222 ns, half-period = 1.111 ns)
    logic clk = 0;
    always #1.111 clk = ~clk;

    // DUT Interface Signals
    logic         rst_n;
    logic         start;
    logic         ready;
    logic         done;
    logic [2:0]   k;
    logic [255:0] seed_d;
    logic [255:0] seed_z;
    logic [1:0]   mode;
    logic [31:0]  cycle_cnt;

    // Memory Query Interface
    logic         mem_rd_en;
    logic         mem_rd_is_dk;
    logic [11:0]  mem_rd_addr;
    logic [7:0]   mem_rd_data;
    logic         mem_rd_valid;

    // Unused streaming outputs / status
    logic         operation_error;
    logic [255:0] shared_secret;
    logic         key_out_valid;
    logic [7:0]   key_out_data;
    logic         key_out_last;
    logic         key_out_is_dk;

    // DUT Instantiation
    mlkem_keygen_top dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .start           (start),
        .ready           (ready),
        .done            (done),
        .k               (k),
        .seed_d          (seed_d),
        .seed_z          (seed_z),
        .mode            (mode),
        .enc_message     (256'd0),
        .ek_in_valid     (1'b0),
        .ek_in_ready     (),
        .ek_in_data      (64'd0),
        .ek_in_last      (1'b0),
        .dk_in_valid     (1'b0),
        .dk_in_ready     (),
        .dk_in_data      (64'd0),
        .dk_in_last      (1'b0),
        .ct_in_valid     (1'b0),
        .ct_in_ready     (),
        .ct_in_data      (88'd0),
        .ct_in_bytes     (4'd0),
        .ct_in_last      (1'b0),
        .operation_error (operation_error),
        .shared_secret   (shared_secret),
        .ct_out_valid    (),
        .ct_out_data     (),
        .ct_out_bytes    (),
        .ct_out_last     (),
        .cycle_cnt       (cycle_cnt),
        .mem_rd_en       (mem_rd_en),
        .mem_rd_is_dk    (mem_rd_is_dk),
        .mem_rd_addr     (mem_rd_addr),
        .mem_rd_data     (mem_rd_data),
        .mem_rd_valid    (mem_rd_valid),
        .key_out_valid   (key_out_valid),
        .key_out_data    (key_out_data),
        .key_out_last    (key_out_last),
        .key_out_is_dk   (key_out_is_dk)
    );

    // Reference vectors
    logic [7:0] exp_seed_d [0:31];
    logic [7:0] exp_seed_z [0:31];
    logic [7:0] exp_ek     [0:EK_LEN-1];
    logic [7:0] exp_dk     [0:DK_LEN-1];

    // Readout storage
    logic [7:0] actual_ek  [0:EK_LEN-1];
    logic [7:0] actual_dk  [0:DK_LEN-1];

    // Status tracking
    integer ek_errors = 0;
    integer dk_errors = 0;
    integer total_errors = 0;
    integer latency_cycles = 0;
    integer wait_timeout = 0;
    integer i;

    // Load KAT vectors
    initial begin
        $readmemh("seed_d.hex", exp_seed_d);
        $readmemh("seed_z.hex", exp_seed_z);
        $readmemh("ek_k3.hex",  exp_ek);
        $readmemh("dk_k3.hex",  exp_dk);
    end

    // Global Watchdog (50,000 cycles)
    integer global_cycles = 0;
    always @(posedge clk) begin
        global_cycles <= global_cycles + 1;
        if (global_cycles > 50000) begin
            $fatal(1, "[GLOBAL TIMEOUT] Watchdog expired in %s at cycle %0d!",
                   MODE_NAME, global_cycles);
        end
    end

    // Main Test Sequence
    initial begin
        // Reset sequence
        rst_n        = 0;
        start        = 0;
        mode         = 2'd0;
        k            = K_PARAM;
        seed_d       = 256'd0;
        seed_z       = 256'd0;
        mem_rd_en    = 0;
        mem_rd_is_dk = 0;
        mem_rd_addr  = 0;

        // Wait 150 ns for Xilinx glbl GSR (Global Set/Reset, 100 ns) to release
        #150;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5)  @(posedge clk);

        // Pack 32-byte seed arrays into 256-bit DUT input buses
        for (i = 0; i < 32; i++) begin
            seed_d[i*8 +: 8] = exp_seed_d[i];
            seed_z[i*8 +: 8] = exp_seed_z[i];
        end

        // Wait until DUT indicates ready
        wait_timeout = 0;
        @(negedge clk);
        while (!ready && wait_timeout < 2000) begin
            @(negedge clk);
            wait_timeout++;
        end
        if (!ready) begin
            $fatal(1, "[TIMEOUT] %s timed out waiting for ready!", MODE_NAME);
        end

        // Pulse start=1 with mode=0 and designated k
        mode  <= 2'd0;
        k     <= K_PARAM;
        start <= 1'b1;
        @(negedge clk);
        start <= 1'b0;

        // Wait for done
        wait_timeout = 0;
        while (!done && wait_timeout < 20000) begin
            @(negedge clk);
            wait_timeout++;
        end
        if (!done) begin
            $fatal(1, "[TIMEOUT] %s timed out waiting for done after %0d cycles!",
                   MODE_NAME, wait_timeout);
        end

        latency_cycles = cycle_cnt;

        // Read back generated ek byte-by-byte using mem_rd_* interface
        ek_errors = 0;
        for (i = 0; i < EK_LEN; i++) begin
            mem_rd_en    <= 1'b1;
            mem_rd_is_dk <= 1'b0;
            mem_rd_addr  <= i[11:0];
            @(posedge clk);
            #1;
            actual_ek[i] = mem_rd_data;
            if (actual_ek[i] !== exp_ek[i]) begin
                if (ek_errors < 5) begin
                    $error("   [ek mismatch] byte[%0d]: got=%02x, exp=%02x", i, actual_ek[i], exp_ek[i]);
                end
                ek_errors++;
            end
        end

        // Read back generated dk byte-by-byte using mem_rd_* interface
        dk_errors = 0;
        for (i = 0; i < DK_LEN; i++) begin
            mem_rd_en    <= 1'b1;
            mem_rd_is_dk <= 1'b1;
            mem_rd_addr  <= i[11:0];
            @(posedge clk);
            #1;
            actual_dk[i] = mem_rd_data;
            if (actual_dk[i] !== exp_dk[i]) begin
                if (dk_errors < 5) begin
                    $error("   [dk mismatch] byte[%0d]: got=%02x, exp=%02x", i, actual_dk[i], exp_dk[i]);
                end
                dk_errors++;
            end
        end

        mem_rd_en <= 1'b0;
        @(posedge clk);

        // Print exact C-Style KAT Trace format
        $display("==================================================================");
        $display(" [C-STYLE KAT TRACE] ML-KEM KeyGen: %s (k=%0d)", MODE_NAME, K_PARAM);
        $display("==================================================================");
        $display("[INPUT] k = %0d", K_PARAM);
        $write("[INPUT] seed_d = ");
        for (i = 0; i < 32; i++) $write("%02x", exp_seed_d[i]);
        $write("\n");
        $write("[INPUT] seed_z = ");
        for (i = 0; i < 32; i++) $write("%02x", exp_seed_z[i]);
        $write("\n");
        $write("[GENERATED] ek = ");
        for (i = 0; i < EK_LEN; i++) $write("%02x", actual_ek[i]);
        $write("\n");
        $write("[GENERATED] dk = ");
        for (i = 0; i < DK_LEN; i++) $write("%02x", actual_dk[i]);
        $write("\n");
        $display("==================================================================");

        // Check error count and print latency cycle count
        total_errors = ek_errors + dk_errors;
        $display("Latency: %0d clock cycles", latency_cycles);
        if (latency_cycles > MAX_CYCLES) begin
            $error("   [FAIL] Latency %0d exceeded maximum limit of %0d cycles!", latency_cycles, MAX_CYCLES);
            total_errors++;
        end else begin
            $display("   [PASS] Latency %0d cycles satisfies budget (limit: %0d cycles).", latency_cycles, MAX_CYCLES);
        end

        if (total_errors == 0) begin
            $display("[PASS] %s KeyGen test passed with 0 errors 100%% bit-exact!", MODE_NAME);
            $finish(0);
        end else begin
            $fatal(1, "[FAIL] %s KeyGen test encountered %0d mismatches (ek: %0d, dk: %0d)!",
                   MODE_NAME, total_errors, ek_errors, dk_errors);
        end
    end

endmodule
