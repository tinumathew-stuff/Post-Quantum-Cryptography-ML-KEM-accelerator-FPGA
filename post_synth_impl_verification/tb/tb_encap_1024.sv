`timescale 1ns/1ps

// =============================================================================
// Testbench Name: tb_encap_1024
// Project:        ML-KEM High-Performance Post-Quantum Cryptographic Accelerator
// Specification:  NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Security Level: ML-KEM-1024 (k=4, Security Category 5)
// Operation:      ML-KEM.Encaps (Algorithm 17)
// =============================================================================

module tb_encap_1024;

    // -------------------------------------------------------------------------
    // Parameters for ML-KEM-1024 (k=4)
    // -------------------------------------------------------------------------
    localparam int K_PARAM    = 4;
    localparam int MODE_PARAM = 1024;
    localparam int PK_BYTES   = 1568;  // k * 384 + 32 = 1568 bytes
    localparam int CT_BYTES   = 1568;  // 32 * (k * d_u + d_v) = 32 * (4 * 11 + 5) = 1568 bytes
    localparam int SS_BYTES   = 32;    // 256 bits = 32 bytes
    localparam int M_BYTES    = 32;    // 256 bits = 32 bytes

    // -------------------------------------------------------------------------
    // Clock and Reset Generation (450 MHz clock: period = 2.222 ns)
    // -------------------------------------------------------------------------
    logic clk = 1'b0;
    always #1.111 clk = ~clk;

    logic         rst_n = 1'b0;
    logic         start = 1'b0;
    logic [1:0]   mode = 2'd1;         // Mode 1: Encapsulation
    logic [2:0]   k = K_PARAM[2:0];    // k = 4 for ML-KEM-1024
    logic [255:0] enc_message = 256'd0;

    // DUT Output Status Signals
    wire          ready;
    wire          done;
    wire          operation_error;
    wire [31:0]   cycle_cnt;
    wire [255:0]  shared_secret;

    // Public Key (ek) Streaming Interface
    logic         ek_in_valid = 1'b0;
    wire          ek_in_ready;
    logic [63:0]  ek_in_data = 64'd0;
    logic         ek_in_last = 1'b0;

    // Ciphertext Streaming Output Interface
    wire          ct_out_valid;
    wire [87:0]   ct_out_data;
    wire [3:0]    ct_out_bytes;
    wire          ct_out_last;

    // Synchronous Memory Query Interface (1-Cycle Latency)
    logic         mem_rd_en = 1'b0;
    logic         mem_rd_is_dk = 1'b0;
    logic [11:0]  mem_rd_addr = 12'd0;
    wire [7:0]    mem_rd_data;
    wire          mem_rd_valid;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    // -------------------------------------------------------------------------
    mlkem_keygen_top dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .ready          (ready),
        .done           (done),
        .k              (k),
        .seed_d         (256'd0),
        .seed_z         (256'd0),
        .mode           (mode),
        .enc_message    (enc_message),
        .ek_in_valid    (ek_in_valid),
        .ek_in_ready    (ek_in_ready),
        .ek_in_data     (ek_in_data),
        .ek_in_last     (ek_in_last),
        .dk_in_valid    (1'b0),
        .dk_in_ready    (),
        .dk_in_data     (64'd0),
        .dk_in_last     (1'b0),
        .ct_in_valid    (1'b0),
        .ct_in_ready    (),
        .ct_in_data     (88'd0),
        .ct_in_bytes    (4'd0),
        .ct_in_last     (1'b0),
        .operation_error(operation_error),
        .shared_secret  (shared_secret),
        .ct_out_valid   (ct_out_valid),
        .ct_out_data    (ct_out_data),
        .ct_out_bytes   (ct_out_bytes),
        .ct_out_last    (ct_out_last),
        .cycle_cnt      (cycle_cnt),
        .mem_rd_en      (mem_rd_en),
        .mem_rd_is_dk   (mem_rd_is_dk),
        .mem_rd_addr    (mem_rd_addr),
        .mem_rd_data    (mem_rd_data),
        .mem_rd_valid   (mem_rd_valid),
        .key_out_valid  (),
        .key_out_data   (),
        .key_out_last   (),
        .key_out_is_dk  ()
    );

    // -------------------------------------------------------------------------
    // Test Vectors and Storage Arrays
    // -------------------------------------------------------------------------
    logic [7:0] pk     [0:PK_BYTES-1];
    logic [7:0] m      [0:M_BYTES-1];
    logic [7:0] exp_ct [0:CT_BYTES-1];
    logic [7:0] exp_ss [0:SS_BYTES-1];

    logic [7:0] actual_ct [0:CT_BYTES-1];
    integer     ct_index = 0;
    integer     error_count = 0;

    // -------------------------------------------------------------------------
    // Capture Streamed Ciphertext
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && ct_out_valid) begin
            for (int b = 0; b < ct_out_bytes; b++) begin
                if (ct_index + b < CT_BYTES) begin
                    actual_ct[ct_index + b] = ct_out_data[b*8 +: 8];
                end
            end
            ct_index = ct_index + ct_out_bytes;
        end
    end

    // -------------------------------------------------------------------------
    // Watchdog Timer
    // -------------------------------------------------------------------------
    initial begin
        #50000;
        $fatal(1, "[TIMEOUT] Testbench tb_encap_1024 timed out after 50 us!");
    end

    // -------------------------------------------------------------------------
    // Main Verification Process
    // -------------------------------------------------------------------------
    initial begin
        // Initialize control signals and storage
        rst_n        = 1'b0;
        start        = 1'b0;
        mode         = 2'd1;
        k            = K_PARAM[2:0];
        enc_message  = 256'd0;
        ek_in_valid  = 1'b0;
        ek_in_data   = 64'd0;
        ek_in_last   = 1'b0;
        mem_rd_en    = 1'b0;
        mem_rd_is_dk = 1'b0;
        mem_rd_addr  = 12'd0;
        ct_index     = 0;
        error_count  = 0;

        for (int i = 0; i < CT_BYTES; i++) begin
            actual_ct[i] = 8'h00;
        end

        // Load golden reference vectors
        $readmemh("pk_1024.hex", pk, 0, PK_BYTES - 1);
        $readmemh("m_1024.hex", m, 0, M_BYTES - 1);
        $readmemh("ct_1024.hex", exp_ct, 0, CT_BYTES - 1);
        $readmemh("ss_1024.hex", exp_ss, 0, SS_BYTES - 1);

        // Pack message m into 256-bit enc_message (little-endian byte order)
        for (int b = 0; b < 32; b++) begin
            enc_message[b*8 +: 8] = m[b];
        end

        // Apply reset sequence (wait 150 ns for Xilinx glbl GSR deassertion)
        #150;
        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // Wait for accelerator ready
        while (!ready) @(posedge clk);

        // Assert start pulse for 1 clock cycle
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Stream public key (pk) in 64-bit lanes
        for (int a = 0; a < PK_BYTES; a += 8) begin
            @(negedge clk);
            ek_in_valid = 1'b1;
            for (int b = 0; b < 8; b++) begin
                ek_in_data[b*8 +: 8] = pk[a + b];
            end
            ek_in_last = (a == (PK_BYTES - 8));
            do @(posedge clk); while (!ek_in_ready);
        end
        @(negedge clk);
        ek_in_valid = 1'b0;
        ek_in_data  = 64'd0;
        ek_in_last  = 1'b0;

        // Wait for operation completion
        while (!done) @(posedge clk);
        @(negedge clk);

        // Check for hardware operation error
        if (operation_error) begin
            $display("[ERROR] DUT asserted unexpected operation_error!");
            error_count++;
        end

        // Verify total streamed ciphertext byte count
        if (ct_index != CT_BYTES) begin
            $display("[ERROR] Streamed ciphertext byte count mismatch: got %0d, expected %0d", ct_index, CT_BYTES);
            error_count++;
        end

        // Verify streamed ciphertext byte-by-byte
        for (int i = 0; i < CT_BYTES; i++) begin
            if (actual_ct[i] !== exp_ct[i]) begin
                $display("[ERROR] Streamed ciphertext mismatch at byte %0d: got %02x, exp %02x", i, actual_ct[i], exp_ct[i]);
                error_count++;
            end
        end

        // Verify shared secret from output port byte-by-byte
        for (int b = 0; b < 32; b++) begin
            if (shared_secret[b*8 +: 8] !== exp_ss[b]) begin
                $display("[ERROR] Shared secret mismatch at byte %0d: got %02x, exp %02x", b, shared_secret[b*8 +: 8], exp_ss[b]);
                error_count++;
            end
        end

        // Verify retained ciphertext via synchronous memory query interface
        for (int a = 0; a < CT_BYTES; a++) begin
            mem_rd_en    = 1'b1;
            mem_rd_is_dk = 1'b0;
            mem_rd_addr  = a[11:0];
            @(negedge clk);
            if (!mem_rd_valid || mem_rd_data !== exp_ct[a]) begin
                $display("[ERROR] Retained ciphertext mismatch at addr %0d: got %02x, exp %02x", a, mem_rd_data, exp_ct[a]);
                error_count++;
            end
        end
        mem_rd_en = 1'b0;
        @(negedge clk);

        // Verify retained shared secret via synchronous memory query interface
        for (int a = 0; a < 32; a++) begin
            mem_rd_en    = 1'b1;
            mem_rd_is_dk = 1'b1;
            mem_rd_addr  = a[11:0];
            @(negedge clk);
            if (!mem_rd_valid || mem_rd_data !== exp_ss[a]) begin
                $display("[ERROR] Retained shared secret mismatch at addr %0d: got %02x, exp %02x", a, mem_rd_data, exp_ss[a]);
                error_count++;
            end
        end
        mem_rd_en = 1'b0;
        @(negedge clk);

        // Print exact C-Style KAT Trace format
        $display("==================================================================");
        $display(" [C-STYLE KAT TRACE] ML-KEM Encapsulation: ML-KEM-%0d (k=%0d)", MODE_PARAM, K_PARAM);
        $display("==================================================================");
        $display("[INPUT] k = %0d", K_PARAM);
        $write("[INPUT] m = ");
        for (int i = 0; i < 32; i++) $write("%02x", m[i]);
        $write("\n");
        $write("[INPUT] pk = ");
        for (int i = 0; i < PK_BYTES; i++) $write("%02x", pk[i]);
        $write("\n");
        $write("[GENERATED] ct = ");
        for (int i = 0; i < CT_BYTES; i++) $write("%02x", actual_ct[i]);
        $write("\n");
        $write("[GENERATED] ss = ");
        for (int i = 0; i < 32; i++) $write("%02x", shared_secret[i*8 +: 8]);
        $write("\n");
        $display("==================================================================");

        // Report verification results and execution latency
        if (error_count == 0) begin
            $display("[PASS] ML-KEM-%0d Encapsulation verified successfully with 0 errors.", MODE_PARAM);
            $display("Execution Latency: %0d clock cycles", cycle_cnt);
            $finish(0);
        end else begin
            $display("TEST FAILED: ML-KEM-%0d Encapsulation encountered %0d errors!", MODE_PARAM, error_count);
            $finish(1);
        end
    end

endmodule
