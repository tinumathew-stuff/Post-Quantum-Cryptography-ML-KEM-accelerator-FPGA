`timescale 1ns/1ps

// =============================================================================
// Testbench Name: tb_decap_512
// Project:        ML-KEM High-Performance Post-Quantum Cryptographic Accelerator
// Specification:  NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Operation:      ML-KEM-512 Decapsulation (k=2, du=10, dv=4)
// =============================================================================

module tb_decap_512;

    // -------------------------------------------------------------------------
    // Parameters for ML-KEM-512 (k=2)
    // -------------------------------------------------------------------------
    localparam int K         = 2;
    localparam int DU        = 10;
    localparam int DV        = 4;
    localparam int DKLEN     = 1632;
    localparam int CTLEN     = 768;
    localparam string MODE_NAME = "ML-KEM-512";

    // -------------------------------------------------------------------------
    // Clock and Reset Signals
    // -------------------------------------------------------------------------
    // 450 MHz clock generation (period = 2.222 ns: #1.111 high / #1.111 low)
    logic clk = 0;
    always #1.111 clk = ~clk;

    logic rst_n = 0;
    logic start = 0;
    logic [1:0] mode = 2'd2;         // Mode 2: Decapsulation (ML-KEM.Decaps)
    logic [2:0] k = K[2:0];          // Security level k=2
    logic [255:0] seed_d = 256'd0;
    logic [255:0] seed_z = 256'd0;
    logic [255:0] enc_message = 256'd0;

    // Encapsulation Key Ingress (Unused in pure Decap)
    logic ek_in_valid = 0;
    logic ek_in_last = 0;
    logic [63:0] ek_in_data = 64'd0;
    wire ek_in_ready;

    // Decapsulation Key (dk) Ingress (64-bit lanes)
    logic dk_in_valid = 0;
    logic dk_in_last = 0;
    logic [63:0] dk_in_data = 64'd0;
    wire dk_in_ready;

    // Ciphertext (ct) Ingress (88-bit groups)
    logic ct_in_valid = 0;
    logic ct_in_last = 0;
    logic [87:0] ct_in_data = 88'd0;
    logic [3:0] ct_in_bytes = 4'd0;
    wire ct_in_ready;

    // DUT Output Status Signals
    wire ready;
    wire done;
    wire operation_error;
    wire [31:0] cycle_cnt;
    wire [255:0] shared_secret;

    // Ciphertext Output Signals (Masked during Decap)
    wire ct_out_valid;
    wire [87:0] ct_out_data;
    wire [3:0] ct_out_bytes;
    wire ct_out_last;

    // Synchronous Memory Query Interface (1-Cycle Latency)
    logic mem_rd_en = 0;
    logic mem_rd_is_dk = 1;
    logic [11:0] mem_rd_addr = 12'd0;
    wire [7:0] mem_rd_data;
    wire mem_rd_valid;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    // -------------------------------------------------------------------------
    mlkem_keygen_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .ready(ready),
        .done(done),
        .k(k),
        .seed_d(seed_d),
        .seed_z(seed_z),
        .mode(mode),
        .enc_message(enc_message),
        .ek_in_valid(ek_in_valid),
        .ek_in_ready(ek_in_ready),
        .ek_in_data(ek_in_data),
        .ek_in_last(ek_in_last),
        .dk_in_valid(dk_in_valid),
        .dk_in_ready(dk_in_ready),
        .dk_in_data(dk_in_data),
        .dk_in_last(dk_in_last),
        .ct_in_valid(ct_in_valid),
        .ct_in_ready(ct_in_ready),
        .ct_in_data(ct_in_data),
        .ct_in_bytes(ct_in_bytes),
        .ct_in_last(ct_in_last),
        .operation_error(operation_error),
        .shared_secret(shared_secret),
        .ct_out_valid(ct_out_valid),
        .ct_out_data(ct_out_data),
        .ct_out_bytes(ct_out_bytes),
        .ct_out_last(ct_out_last),
        .cycle_cnt(cycle_cnt),
        .mem_rd_en(mem_rd_en),
        .mem_rd_is_dk(mem_rd_is_dk),
        .mem_rd_addr(mem_rd_addr),
        .mem_rd_data(mem_rd_data),
        .mem_rd_valid(mem_rd_valid)
    );

    // -------------------------------------------------------------------------
    // Test Vector Storage Arrays
    // -------------------------------------------------------------------------
    logic [7:0] dk_mem [0:DKLEN-1];
    logic [7:0] ct_mem [0:CTLEN-1];
    logic [7:0] exp_ss [0:31];

    int errors = 0;

    // -------------------------------------------------------------------------
    // Load KAT Hex Vectors
    // -------------------------------------------------------------------------
    initial begin
        $readmemh("dk_512.hex", dk_mem, 0, DKLEN-1);
        $readmemh("ct_512.hex", ct_mem, 0, CTLEN-1);
        $readmemh("ss_512.hex", exp_ss, 0, 31);
    end

    // -------------------------------------------------------------------------
    // Safety Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #100000;
        $fatal(1, "[WATCHDOG TIMEOUT] Simulation hung in %s testbench!", MODE_NAME);
    end

    // -------------------------------------------------------------------------
    // Task: send_dk
    // Streams secret key dk in 64-bit lanes over dk_in_* interface
    // -------------------------------------------------------------------------
    task automatic send_dk;
        for (int off = 0; off < DKLEN; off += 8) begin
            @(negedge clk);
            if (done) break;
            dk_in_valid = 1'b1;
            dk_in_last  = (off + 8 == DKLEN);
            dk_in_data  = 64'd0;
            for (int a = 0; a < 8; a++) begin
                dk_in_data[8*a +: 8] = dk_mem[off + a];
            end
            do @(posedge clk); while (!dk_in_ready && !done);
        end
        @(negedge clk);
        dk_in_valid = 1'b0;
        dk_in_last  = 1'b0;
        dk_in_data  = 64'd0;
    endtask

    // -------------------------------------------------------------------------
    // Task: send_ct
    // Streams ciphertext groups over ct_in_* interface
    // -------------------------------------------------------------------------
    task automatic send_ct;
        int off;
        off = 0;
        for (int group = 0; group < 32*(K+1); group++) begin
            @(negedge clk);
            if (done) break;
            ct_in_valid = 1'b1;
            ct_in_bytes = (group < 32*K) ? DU : DV;
            ct_in_last  = (group == 32*(K+1) - 1);
            ct_in_data  = 88'd0;
            for (int a = 0; a < ct_in_bytes; a++) begin
                ct_in_data[8*a +: 8] = ct_mem[off + a];
            end
            off += ct_in_bytes;
            do @(posedge clk); while (!ct_in_ready && !done);
        end
        @(negedge clk);
        ct_in_valid = 1'b0;
        ct_in_last  = 1'b0;
        ct_in_bytes = 4'd0;
        ct_in_data  = 88'd0;
    endtask

    // -------------------------------------------------------------------------
    // Task: print_decap_trace
    // Formats and prints exact C-style NIST KAT trace log
    // -------------------------------------------------------------------------
    task automatic print_decap_trace;
        $display("==================================================================");
        $display(" [C-STYLE KAT TRACE] ML-KEM Decapsulation: %s (k=%0d)", MODE_NAME, K);
        $display("==================================================================");
        $display("[INPUT] k = %0d", K);
        $write("[INPUT] dk = ");
        for (int i = 0; i < DKLEN; i++) $write("%02x", dk_mem[i]);
        $write("\n");
        $write("[INPUT] ct = ");
        for (int i = 0; i < CTLEN; i++) $write("%02x", ct_mem[i]);
        $write("\n");
        $write("[GENERATED] ss = ");
        for (int i = 0; i < 32; i++) $write("%02x", shared_secret[i*8 +: 8]);
        $write("\n");
        $display("==================================================================");
    endtask

    // -------------------------------------------------------------------------
    // Main Test Sequence
    // -------------------------------------------------------------------------
    initial begin
        // Reset sequence (wait 150 ns for Xilinx glbl GSR deassertion)
        rst_n = 0;
        start = 0;
        #150;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Wait until DUT is ready
        while (!ready) @(posedge clk);

        // Configure mode and initiate command
        @(negedge clk);
        mode  = 2'd2;
        k     = K[2:0];
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Concurrent streaming and completion monitoring
        fork
            send_dk();
            send_ct();
            begin
                wait (done);
            end
        join

        #0.1;

        // Verify status and errors
        if (operation_error) begin
            $display("[ERROR] DUT asserted operation_error!");
            errors++;
        end

        // Verify shared secret from port
        for (int a = 0; a < 32; a++) begin
            if (shared_secret[8*a +: 8] !== exp_ss[a]) begin
                $display("[ERROR] Port shared_secret mismatch at byte %0d: got %02x, expected %02x",
                         a, shared_secret[8*a +: 8], exp_ss[a]);
                errors++;
            end
        end

        // Verify shared secret via memory query interface
        mem_rd_is_dk = 1'b1;
        for (int a = 0; a < 32; a++) begin
            @(negedge clk);
            mem_rd_en   = 1'b1;
            mem_rd_addr = a[11:0];
            @(posedge clk);
            #1.0;
            if (!mem_rd_valid || mem_rd_data !== exp_ss[a]) begin
                $display("[ERROR] Memory readout mismatch at byte %0d: got %02x (valid=%b), expected %02x",
                         a, mem_rd_data, mem_rd_valid, exp_ss[a]);
                errors++;
            end
        end
        @(negedge clk);
        mem_rd_en = 1'b0;

        // Print KAT trace log
        print_decap_trace();

        // Check error count and report latency
        if (errors == 0) begin
            $display("[PASS] %s Decapsulation PASSED with 0 errors!", MODE_NAME);
            $display("[LATENCY] Execution completed in %0d clock cycles.", cycle_cnt);
            $finish(0);
        end else begin
            $display("[FAIL] %s Decapsulation FAILED with %0d errors!", MODE_NAME, errors);
            $finish(1);
        end
    end

endmodule
