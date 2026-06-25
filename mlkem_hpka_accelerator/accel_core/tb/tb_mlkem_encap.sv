`timescale 1ns/1ps

// =============================================================================
// Testbench Name: tb_mlkem_encap
// Project:        ML-KEM High-Performance Post-Quantum Cryptographic Accelerator
// Specification:  NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Operation:      ML-KEM.Encaps (Algorithm 17) & Internal PKE Encryption
// Parameter Sets: ML-KEM-512 (k=2), ML-KEM-768 (k=3), ML-KEM-1024 (k=4)
// Target Devices: AMD Xilinx UltraScale+ / Versal / ASIC Verification Environments
// =============================================================================
// VERIFICATION ENVIRONMENT ARCHITECTURE & COVERAGE OBJECTIVES:
// -----------------------------------------------------------------------------
// 1. NIST FIPS 203 KNOWN ANSWER TEST (KAT) COMPLIANCE:
//    - Ingests 99 complete NIST Known Answer Test (KAT) vector sets across all three
//      security categories (k=2, 3, 4).
//    - Golden vectors loaded dynamically via SystemVerilog `$readmemh` tasks:
//        * Input Public Key (pk): ByteEncode12(t) || rho (k*384 + 32 bytes)
//        * Input Message (m): 32-byte pseudo-random plaintext
//        * Expected Ciphertext (ct): ByteEncode_du(u) || ByteEncode_dv(v)
//        * Expected Shared Secret (ss): 32-byte derived symmetric key
//        * Intermediate Seeds & Hashes: d, z, H(ek), random coins
//        * Algorithmic Sub-stages: vector r, noise e1, noise e2, matrix A^T,
//          forward NTT rhat, pointwise products uvhat, inverse NTT uvintt.
//
// 2. COMPREHENSIVE SUB-PIPELINE & FRAMING ASSERTIONS:
//    - Sampler output framing and coefficient validation (EC_R, EC_E1, EC_E2, EC_MATRIX).
//    - Forward NTT and inverse NTT (INTT) output streaming and polynomial framing.
//    - Pointwise matrix-vector multiplier product row accumulation.
//    - Egress ciphertext packet assembly (88-bit beats) with byte-exact comparison.
//    - Hash sampler Keccak squeeze continuation coverage (rejection sampler corner cases).
//
// 3. LATENCY PROFILING & CYCLE BUDGET VERIFICATION:
//    - Strict latency ceiling enforcement: Encapsulation must complete within
//      3600 clock cycles (3500 standard budget + 100 cycle margin), including public
//      key ingestion, symmetric hashing, matrix sampling, and ciphertext emission.
//    - Cross-verification: Compares internal hardware `cycle_cnt` against independent
//      testbench `external_cycles` counter with zero tolerance for mismatch.
//
// 4. ROBUST NEGATIVE TESTING & STRESS VERIFICATION:
//    - Non-canonical public key rejection: Verifies that public key coefficients
//      greater than or equal to prime modulus q=3329 (e.g., 0xFFFF, 3329) trigger
//      `operation_error` and suppress ciphertext emission.
//    - Packet truncation: Asserts `operation_error` if public key packet ends early.
//    - Missing EOP marker: Asserts `operation_error` if `ek_in_last` is omitted.
//    - Invalid security parameter: Verifies rejection for k not in {2, 3, 4}.
//    - Backpressure tolerance: Tests line-rate stalls with pseudo-random gaps in `ek_in_valid`.
//    - Asynchronous reset interruption: Asserts reset mid-transform and verifies clean recovery.
//    - Unsolicited pin perturbation immunity: Modifies control pins while busy to confirm latching.
//
// 5. POST-COMPLETION RANDOM-ACCESS MEMORY READOUT:
//    - Verifies the 1-cycle synchronous memory query interface (`mem_rd_*`) by reading
//      back every retained byte of generated ciphertext and shared secret.
// =============================================================================

module tb_mlkem_encap;

    // -------------------------------------------------------------------------
    // Clock and Reset Signals
    // -------------------------------------------------------------------------
    logic clk=0;
    // 450 MHz clock generation (period = 2.222 ns: #1.111 high / #1.111 low)
    always #1.111 clk=~clk;

    logic rst_n=0, start=0;
    logic [1:0] mode=1;              // Mode 1: Encapsulation (ML-KEM.Encaps)
    logic [2:0] k=4;                 // Security level parameter: 2, 3, or 4
    logic [255:0] seed_d=0, seed_z=0, enc_message=0;

    // DUT Output Status Signals
    wire ready, done, operation_error;
    wire [31:0] cycle_cnt;

    // Streaming Public Key (ek) Ingress Interface
    logic ek_in_valid=0, ek_in_last=0;
    logic [63:0] ek_in_data=0;
    wire ek_in_ready;

    // Output Shared Secret and Ciphertext Interface
    wire [255:0] shared_secret;
    wire ct_out_valid,ct_out_last;
    wire [87:0] ct_out_data;
    wire [3:0] ct_out_bytes;

    // Synchronous Memory Query Interface (1-Cycle Latency)
    logic mem_rd_en=0,mem_rd_is_dk=0;
    logic [11:0] mem_rd_addr=0;
    wire [7:0] mem_rd_data;
    wire mem_rd_valid;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    // -------------------------------------------------------------------------
    mlkem_keygen_top dut (
        .clk(clk),.rst_n(rst_n),.start(start),.mode(mode),.k(k),.seed_d(seed_d),.seed_z(seed_z),
        .ready(ready),.done(done),.cycle_cnt(cycle_cnt),.enc_message(enc_message),
        .ek_in_valid(ek_in_valid),.ek_in_ready(ek_in_ready),.ek_in_data(ek_in_data),.ek_in_last(ek_in_last),
        .operation_error(operation_error),.shared_secret(shared_secret),
        .ct_out_valid(ct_out_valid),.ct_out_data(ct_out_data),.ct_out_bytes(ct_out_bytes),.ct_out_last(ct_out_last),
        .mem_rd_en(mem_rd_en),.mem_rd_is_dk(mem_rd_is_dk),.mem_rd_addr(mem_rd_addr),
        .mem_rd_data(mem_rd_data),.mem_rd_valid(mem_rd_valid),
        .key_out_valid(),.key_out_data(),.key_out_last(),.key_out_is_dk()
    );

    // -------------------------------------------------------------------------
    // Golden Test Vector Storage Arrays
    // -------------------------------------------------------------------------
    logic [7:0] pk[0:1567],ct[0:1567],ss[0:31],d[0:31],z[0:31],m[0:31],h[0:31],coins[0:31];
    logic [7:0] actual_ct[0:1567];
    logic [11:0] r[0:1023],e1[0:1023],e2[0:255],at[0:4095],rhat[0:1023],uvhat[0:1279],uvintt[0:1279];

    // Tracking Integers, Counters, and Test Flow Flags
    integer test_id=0,pk_len,ct_len,ct_index=0,sample_index=0,fwd_index=0,inv_index=0;
    integer mul_index=0,external_cycles=0,max_cycles[2:4];
    integer last_poly_extra_squeezes=0, partial_last_beat_squeezes=0;
    bit check_stages=0, expect_reject=0;
    integer watchdog=0;
    logic [4:0] previous_phase;

    // -------------------------------------------------------------------------
    // Real-Time Hardware Assertion & Monitoring Logic
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        // Trace encapsulation state transitions for initial regression case
        if (test_id == 0 && dut.enc_active && previous_phase != dut.enc_state_q)
            $display("  enc phase=%0d cycle=%0d",dut.enc_state_q,cycle_cnt);
        previous_phase <= dut.enc_state_q;

        // Trace pipeline commit markers
        if (test_id == 0 && dut.enc_active && dut.p3_valid && dut.p3_is_last_col && dut.p3_beat==63)
            $display("  product row=%0d committed cycle=%0d",dut.p3_row,cycle_cnt);
        if (test_id == 0 && dut.enc_active && dut.enc_inverse && dut.ntt_out_valid && dut.ntt_out_ready && dut.ntt_out_last)
            $display("  inverse row=%0d finished cycle=%0d",dut.ntt_out_poly_index,cycle_cnt);

        // Global watchdog protection against hardware deadlock
        if (ready) watchdog <= 0;
        else watchdog <= watchdog + 1;
        if (watchdog > 20000) $fatal(1,"Global watchdog");

        // Independent external cycle tracking
        if (start && ready) begin
            external_cycles=0;
            ct_index=0;sample_index=0;fwd_index=0;inv_index=0;mul_index=0;
        end else if (dut.enc_active) external_cycles++;

        if (dut.enc_active && dut.enc_s_cmd_valid && dut.sampler_cmd_ready) sample_index=0;

        // Deep pipeline stage validation against NIST precomputed intermediates
        if (dut.enc_active && check_stages) begin
            // Keccak squeeze and restore trigger coverage tracking
            if ((dut.hash_sampler_inst.mat_squeeze || dut.hash_sampler_inst.mat_restore_trig) && dut.hash_sampler_inst.core_ready &&
                dut.hash_sampler_inst.block_idx_q == 3) begin
                if (dut.hash_sampler_inst.is_last_matrix_poly_q) last_poly_extra_squeezes++;
                if (dut.hash_sampler_inst.coeff_is_252_q) partial_last_beat_squeezes++;
            end

            // Assert zero NTT format errors
            if (dut.ntt_cmd_error) $fatal(1,"NTT format error");

            // Verify Sampler outputs: r, e1, e2, and matrix A^T
            if (dut.enc_sample_fire) begin
                if (dut.sampler_out_count !== 4 || dut.sampler_out_last !== ((sample_index%256)==252) ||
                    dut.sampler_out_poly_index !== sample_index/256)
                    $fatal(1,"Sampler framing");
                for (int lane=0;lane<4;lane++) begin
                    case (dut.enc_state_q)
                        dut.EC_R: if (dut.sampler_out_data[lane*12 +:12] !== r[sample_index+lane]) $fatal(1,"r case=%0d index=%0d",test_id,sample_index+lane);
                        dut.EC_E1: if (dut.sampler_out_data[lane*12 +:12] !== e1[sample_index+lane]) $fatal(1,"e1 case=%0d index=%0d",test_id,sample_index+lane);
                        dut.EC_E2: if (dut.sampler_out_data[lane*12 +:12] !== e2[sample_index+lane]) $fatal(1,"e2 case=%0d index=%0d",test_id,sample_index+lane);
                        dut.EC_MATRIX: if (dut.sampler_out_data[lane*12 +:12] !== at[sample_index+lane]) $fatal(1,"At case=%0d index=%0d",test_id,sample_index+lane);
                    endcase
                end
                sample_index+=4;
            end

            // Verify Transform engine outputs: forward NTT (rhat) and inverse NTT (uvintt)
            if (dut.ntt_out_valid && dut.ntt_out_ready) begin
                if (dut.ntt_out_count !== 2 || dut.ntt_out_last !==
                    (((dut.enc_inverse ? inv_index : fwd_index)%256)==254) ||
                    dut.ntt_out_poly_index !== (dut.enc_inverse ? inv_index : fwd_index)/256)
                    $fatal(1,"Transform framing");
                for (int lane=0;lane<2;lane++) begin
                    if (!dut.enc_inverse) begin
                        if (dut.ntt_out_data[lane*12 +:12] !== rhat[fwd_index+lane])
                            $fatal(1,"rhat case=%0d index=%0d got=%0d exp=%0d",test_id,fwd_index+lane,dut.ntt_out_data[lane*12 +:12],rhat[fwd_index+lane]);
                    end else if (dut.ntt_out_data[lane*12 +:12] !== uvintt[inv_index+lane])
                        $fatal(1,"INTT case=%0d index=%0d got=%0d exp=%0d",test_id,inv_index+lane,dut.ntt_out_data[lane*12 +:12],uvintt[inv_index+lane]);
                end
                if (dut.enc_inverse) inv_index+=2; else fwd_index+=2;
            end

            // Verify Matrix-Vector multiplier row accumulation output
            if (dut.p3_valid && dut.p3_is_last_col) begin
                for (int lane=0;lane<4;lane++)
                    if (dut.p3_final[lane*12 +:12] !== uvhat[mul_index+lane])
                        $fatal(1,"product case=%0d index=%0d got=%0d exp=%0d",test_id,mul_index+lane,dut.p3_final[lane*12 +:12],uvhat[mul_index+lane]);
                mul_index+=4;
            end

            // Verify Ciphertext streaming output byte-by-byte
            if (ct_out_valid) begin
                for (int b=0;b<ct_out_bytes;b++) begin
                    actual_ct[ct_index+b] = ct_out_data[b*8 +:8];
                    if (ct_out_data[b*8 +:8] !== ct[ct_index+b])
                        $fatal(1,"Ciphertext case=%0d byte=%0d got=%02x exp=%02x",test_id,ct_index+b,ct_out_data[b*8 +:8],ct[ct_index+b]);
                end
                ct_index+=ct_out_bytes;
                if (ct_out_last !== (ct_index==ct_len)) $fatal(1,"Ciphertext last framing");
            end
        end

        // Ensure invalid public keys do not emit spurious ciphertext
        if (expect_reject && ct_out_valid) $fatal(1,"Invalid key emitted ciphertext");
    end

    // -------------------------------------------------------------------------
    // Task: load_case
    // Loads test vector hex files corresponding to given test_id
    // -------------------------------------------------------------------------
    task automatic load_case(input integer id);
        test_id=id;
        // Parameter rotation: 0 -> k=4 (1024), 1 -> k=2 (512), 2 -> k=3 (768)
        k = id%3==0 ? 4 : id%3==1 ? 2 : 3;
        pk_len=k*384+32;
        ct_len=k==4 ? 1568 : k==3 ? 1088 : 768;
        $readmemh($sformatf("enc_%02d_pk.hex",id),pk,0,pk_len-1);
        $readmemh($sformatf("enc_%02d_ct.hex",id),ct,0,ct_len-1);
        $readmemh($sformatf("enc_%02d_ss.hex",id),ss);
        $readmemh($sformatf("enc_%02d_d.hex",id),d);
        $readmemh($sformatf("enc_%02d_z.hex",id),z);
        $readmemh($sformatf("enc_%02d_m.hex",id),m);
        $readmemh($sformatf("enc_%02d_h.hex",id),h);
        $readmemh($sformatf("enc_%02d_coins.hex",id),coins);
        $readmemh($sformatf("enc_%02d_r.hex",id),r,0,k*256-1);
        $readmemh($sformatf("enc_%02d_e1.hex",id),e1,0,k*256-1);
        $readmemh($sformatf("enc_%02d_e2.hex",id),e2);
        $readmemh($sformatf("enc_%02d_at.hex",id),at,0,k*k*256-1);
        $readmemh($sformatf("enc_%02d_rhat.hex",id),rhat,0,k*256-1);
        $readmemh($sformatf("enc_%02d_uvhat.hex",id),uvhat,0,(k+1)*256-1);
        $readmemh($sformatf("enc_%02d_uvintt.hex",id),uvintt,0,(k+1)*256-1);
        for (int b=0;b<32;b++) begin seed_d[b*8 +:8]=d[b];seed_z[b*8 +:8]=z[b];enc_message[b*8 +:8]=m[b];end
    endtask

    // -------------------------------------------------------------------------
    // Task: command
    // Issues single-cycle start pulse to DUT with selected mode
    // -------------------------------------------------------------------------
    task automatic command(input bit enc);
        @(negedge clk);
        if (!ready) $fatal(1,"Command when not ready");
        mode=enc;start=1;
        @(negedge clk); start=0;
    endtask

    // -------------------------------------------------------------------------
    // Task: send_key
    // Streams encapsulation key (pk) into DUT via 64-bit lanes with optional gaps
    // -------------------------------------------------------------------------
    task automatic send_key(input bit gaps, input integer limit, input bit omit_last=0);
        for (int a=0;a<limit;a+=8) begin
            if (gaps && (a%40)==0) begin
                ek_in_valid=0;
                repeat(3) @(negedge clk);
            end
            ek_in_valid=1;
            for (int b=0;b<8;b++) ek_in_data[b*8 +:8]=pk[a+b];
            ek_in_last=(a==limit-8) && !omit_last;
            do @(posedge clk); while (!ek_in_ready);
            @(negedge clk);
        end
        ek_in_valid=0;ek_in_last=0;
    endtask

    // -------------------------------------------------------------------------
    // Task: finish_enc
    // Awaits operation completion, verifies results, checks timing budget & memory readout
    // -------------------------------------------------------------------------
    task automatic finish_enc(input bit performance);
        integer waited;
        waited=0;
        while (!done && waited<7000) begin @(negedge clk); waited++; end
        if (!done) $fatal(1,"Timeout state=%0d ntt=%0d products=%b",dut.enc_state_q,dut.enc_ntt_state_q,dut.enc_product_ready_q);
        if (operation_error) $fatal(1,"Unexpected encapsulation error case=%0d",test_id);
        if (ct_index!=ct_len || fwd_index!=k*256 || inv_index!=(k+1)*256 || mul_index!=(k+1)*256) $fatal(1,"Incomplete output");
        for (int b=0;b<32;b++) begin
            if (shared_secret[b*8 +:8] !== ss[b]) $fatal(1,"Shared secret mismatch byte=%0d",b);
            if (dut.enc_h_q[b*8 +:8] !== h[b] || dut.enc_coins_q[b*8 +:8] !== coins[b]) $fatal(1,"Hash mismatch byte=%0d",b);
        end
        if (cycle_cnt !== external_cycles) $fatal(1,"Cycle counter mismatch %0d/%0d",cycle_cnt,external_cycles);
        $display("PASS encaps case=%0d k=%0d cycles=%0d (includes public-key input and both hashes)",test_id,k,cycle_cnt);

        // Print all inputs fed and generated outputs in C / NIST KAT format
        $display("");
        $display("==================================================================");
        $display(" [C-STYLE KAT TRACE] ML-KEM Encapsulation: Case %0d (k=%0d)", test_id, k);
        $display("==================================================================");
        $display("[INPUT] k = %0d", k);
        $write("[INPUT] m = ");
        for (int i = 0; i < 32; i++) $write("%02x", m[i]);
        $write("\n");
        $write("[INPUT] pk = ");
        for (int i = 0; i < pk_len; i++) $write("%02x", pk[i]);
        $write("\n");
        $write("[GENERATED] ct = ");
        for (int i = 0; i < ct_len; i++) $write("%02x", actual_ct[i]);
        $write("\n");
        $write("[GENERATED] ss = ");
        for (int i = 0; i < 32; i++) $write("%02x", shared_secret[i*8 +: 8]);
        $write("\n");
        $display("==================================================================");
        $display("");
        if (performance && cycle_cnt>3600) $fatal(1,"Encapsulation exceeds 3500+100 cycle budget");
        if (performance && cycle_cnt>max_cycles[k]) max_cycles[k]=cycle_cnt;
        // Query every retained ciphertext byte; change addresses on negative edges.
        for (int a=0;a<ct_len;a++) begin
            mem_rd_en=1;mem_rd_is_dk=0;mem_rd_addr=a;
            @(negedge clk);
            if (!mem_rd_valid || mem_rd_data !== ct[a]) $fatal(1,"Retained ciphertext byte=%0d",a);
        end
        for (int a=0;a<32;a++) begin
            mem_rd_is_dk=1;mem_rd_addr=a;
            @(negedge clk);
            if (!mem_rd_valid || mem_rd_data !== ss[a]) $fatal(1,"Retained shared-secret byte=%0d",a);
        end
        mem_rd_en=0;
        @(negedge clk);
        if (mem_rd_valid) $fatal(1,"Read-valid remained asserted without a request");
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Flow
    // -------------------------------------------------------------------------
    initial begin
        for (int i=2;i<=4;i++) max_cycles[i]=0;
        repeat(6) @(negedge clk); rst_n=1;
        // No KeyGen or initialized operand RAM is required for encapsulation.
        load_case(0);check_stages=1;command(1);send_key(0,pk_len);finish_enc(1);
        for (int id=0;id<99;id++) begin
            load_case(id);
            // Exercise mode transitions without reset, including k=4 -> 2 -> 3.
            if (id<3) begin
                check_stages=0; command(0);
                wait(done); @(negedge clk);
                for (int a=0;a<pk_len;a++) begin
                    mem_rd_en=1;mem_rd_is_dk=0;mem_rd_addr=a;
                    @(negedge clk);
                    if (mem_rd_data !== pk[a]) $fatal(1,"Mixed-mode keygen byte=%0d",a);
                end
                mem_rd_en=0;
            end
            check_stages=1;command(1);send_key(0,pk_len);
            if (id==0) begin
                // Live pins and an unaccepted command cannot modify an operation.
                mode=0;k=2;enc_message=~enc_message;start=1;
                repeat(7) @(negedge clk);
                start=0;mode=1;k=4;enc_message=~enc_message;
            end
            finish_enc(1);
        end
        load_case(0);check_stages=1;command(1);send_key(1,pk_len);finish_enc(0);
        // Reject noncanonical public key, then recover without reset.
        load_case(1);pk[0]=8'hff;pk[1]=8'hff;
        check_stages=0;expect_reject=1;command(1);send_key(0,pk_len);
        wait(done);@(negedge clk);
        if (!operation_error || shared_secret !== 0) $fatal(1,"Bad key accepted");
        load_case(1);pk[0]=8'h01;pk[1]={pk[1][7:4],4'hd};
        command(1);send_key(0,pk_len);
        wait(done);@(negedge clk);
        if (!operation_error) $fatal(1,"Coefficient equal to q accepted");
        // Reject a truncated packet, and release all shared engine state.
        load_case(2);command(1);send_key(0,16);
        wait(done);@(negedge clk);
        if (!operation_error) $fatal(1,"Truncated key accepted");
        load_case(1);command(1);send_key(0,pk_len,1);
        wait(done);@(negedge clk);
        if (!operation_error) $fatal(1,"Missing final marker accepted");
        for (int bad_k=0;bad_k<8;bad_k++) begin
            if (bad_k>=2 && bad_k<=4) continue;
            k=bad_k;command(1);
            wait(done);@(negedge clk);
            if (!operation_error || ek_in_ready) $fatal(1,"Invalid security level accepted");
        end
        expect_reject=0;
        load_case(2);check_stages=1;command(1);send_key(0,pk_len);finish_enc(1);
        // Reset during an active forward transform, then retry at another level.
        load_case(0);check_stages=0;command(1);send_key(0,pk_len);
        wait(dut.enc_ntt_state_q==1 && dut.ntt_out_valid);
        @(negedge clk);rst_n=0;
        repeat(6) @(negedge clk);rst_n=1;
        load_case(1);check_stages=1;command(1);send_key(0,pk_len);finish_enc(1);
        $display("COVER last-poly extra squeezes=%0d partial-final-beat squeezes=%0d",last_poly_extra_squeezes,partial_last_beat_squeezes);
        if (last_poly_extra_squeezes==0 || partial_last_beat_squeezes==0)
            $fatal(1,"Rejection continuation corner cases not covered");
        $display("MAX cycles k2=%0d k3=%0d k4=%0d",max_cycles[2],max_cycles[3],max_cycles[4]);
        $display("ALL ML-KEM ENCAPSULATION REGRESSIONS PASSED");
        $finish;
    end
endmodule
