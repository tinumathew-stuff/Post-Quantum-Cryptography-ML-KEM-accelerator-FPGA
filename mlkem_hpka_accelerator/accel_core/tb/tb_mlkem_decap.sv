`timescale 1ns/1ps

// =============================================================================
// Testbench Name: tb_mlkem_decap
// Project:        ML-KEM High-Performance Post-Quantum Cryptographic Accelerator
// Specification:  NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Operation:      ML-KEM.Decaps (Algorithm 18) & Fujisaki-Okamoto (FO) Transform
// Parameter Sets: ML-KEM-512 (k=2), ML-KEM-768 (k=3), ML-KEM-1024 (k=4)
// Target Devices: AMD Xilinx UltraScale+ / Versal / ASIC Verification Environments
// =============================================================================
// VERIFICATION ENVIRONMENT ARCHITECTURE & COVERAGE OBJECTIVES:
// -----------------------------------------------------------------------------
// 1. NIST FIPS 203 DECAPSULATION & FO TRANSFORM VERIFICATION:
//    - Full verification of ML-KEM.Decaps incorporating the Fujisaki-Okamoto transform:
//        Step 1: Parse decapsulation key dk = (s || ek || H(ek) || z).
//        Step 2: Parse ciphertext c = (u || v).
//        Step 3: Decrypt ciphertext m' = Compress(v - s^T * INTT(u)).
//        Step 4: Re-encrypt (K', r') = G(m' || H(ek)), c' = Encaps(ek, m', r').
//        Step 5: Constant-time comparison: c == c'.
//        Step 6: Implicit Rejection: If valid (c == c'), return K = J(K' || H(c)) or K';
//                if invalid (c != c'), return pseudorandom rejection key K = J(z || H(c)).
//    - Golden KAT test vectors dynamically loaded for 99 cases x 5 variants:
//        * Variant 0: Valid ciphertext -> verifies correct decapsulation to golden K.
//        * Variants 1-4: Corrupted / tampered ciphertexts -> verifies implicit rejection
//          producing pseudorandom rejection key j without asserting operation_error.
//
// 2. CONSTANT-TIME TIMING INVARIANCE (SIDE-CHANNEL DEFENSE):
//    - Crucial security assertion: Verifies that decapsulation latency for invalid
//      ciphertexts (variants 1-3) is identical to valid ciphertexts (variant 0) to
//      the exact cycle (`cycle_cnt == normal_cycles[id]`). This proves zero timing
//      leakage on ciphertext validity, defending against timing oracle attacks.
//
// 3. ZERO INFORMATION LEAKAGE ON INTERFACES:
//    - Confirms that during decapsulation, ciphertext egress signals are fully
//      masked (`ct_out_valid == 0`, `ct_out_data == 0`, `ct_out_bytes == 0`).
//    - Confirms shared_secret remains 0 until `done` is asserted.
//    - Confirms unauthorized memory reads to internal decapsulation buffers return 0.
//
// 4. MULTI-OPERATIONAL MODE TRANSITIONS:
//    - Exercises consecutive transitions between KeyGen (mode 0), Encapsulation
//      (mode 1), and Decapsulation (mode 2) without intermediate hardware resets.
//
// 5. FAULT INJECTION & CORNER CASES:
//    - Invalid parameter k (k not in {2, 3, 4}).
//    - Corrupted decapsulation key components (s, t, H(ek)).
//    - Non-canonical coefficients (>= 3329) in secret key and public key.
//    - Premature and missing packet termination markers (dk_in_last, ct_in_last).
//    - Invalid byte width counts in ciphertext stream.
//    - Mid-execution asynchronous reset interruption at multiple pipeline phases.
// =============================================================================

module tb_mlkem_decap;

    // -------------------------------------------------------------------------
    // Clock and Reset Signals
    // -------------------------------------------------------------------------
    logic clk=0;
    // 450 MHz clock generation (period = 2.222 ns: #1.111 high / #1.111 low)
    always #1.111 clk=~clk;

    logic rst_n=0,start=0;
    logic [1:0] mode=2;              // Mode 2: Decapsulation (ML-KEM.Decaps)
    logic [2:0] k=4;                 // Security level parameter: 2, 3, or 4
    logic [255:0] seed_d=0,seed_z=0;
    logic [255:0] enc_message=0;

    // Encapsulation Key Ingress (Unused in pure Decap)
    logic ek_in_valid=0,ek_in_last=0;
    logic [63:0] ek_in_data=0;
    wire ek_in_ready;

    // Ciphertext Output Signals (Masked during Decap)
    wire [87:0] ct_out_data;
    wire [3:0] ct_out_bytes;
    wire ct_out_last;

    // DUT Output Status Signals
    wire ready,done,operation_error;
    wire [31:0] cycle_cnt;
    wire [255:0] shared_secret;

    // Decapsulation Ingress Streaming Interfaces
    logic dk_in_valid=0,dk_in_last=0,ct_in_valid=0,ct_in_last=0;
    logic [63:0] dk_in_data=0;
    logic [87:0] ct_in_data=0;
    logic [3:0] ct_in_bytes=0;
    wire dk_in_ready,ct_in_ready,ct_out_valid;

    // Synchronous Memory Query Interface (1-Cycle Latency)
    logic mem_rd_en=0,mem_rd_is_dk=1;
    logic [11:0] mem_rd_addr=0;
    wire [7:0] mem_rd_data;
    wire mem_rd_valid;

    // -------------------------------------------------------------------------
    // Device Under Test (DUT) Instantiation
    // -------------------------------------------------------------------------
    mlkem_keygen_top dut (
        .clk(clk),.rst_n(rst_n),.start(start),.mode(mode),.k(k),.seed_d(seed_d),.seed_z(seed_z),
        .ready(ready),.done(done),.operation_error(operation_error),.cycle_cnt(cycle_cnt),.shared_secret(shared_secret),
        .enc_message(enc_message),.ek_in_valid(ek_in_valid),.ek_in_ready(ek_in_ready),.ek_in_data(ek_in_data),.ek_in_last(ek_in_last),
        .dk_in_valid(dk_in_valid),.dk_in_ready(dk_in_ready),.dk_in_data(dk_in_data),.dk_in_last(dk_in_last),
        .ct_in_valid(ct_in_valid),.ct_in_ready(ct_in_ready),.ct_in_data(ct_in_data),.ct_in_bytes(ct_in_bytes),.ct_in_last(ct_in_last),
        .ct_out_valid(ct_out_valid),.ct_out_data(ct_out_data),.ct_out_bytes(ct_out_bytes),.ct_out_last(ct_out_last),
        .mem_rd_en(mem_rd_en),.mem_rd_is_dk(mem_rd_is_dk),.mem_rd_addr(mem_rd_addr),
        .mem_rd_data(mem_rd_data),.mem_rd_valid(mem_rd_valid)
    );

    // -------------------------------------------------------------------------
    // Golden Test Vector Storage Arrays
    // -------------------------------------------------------------------------
    logic [7:0] dk[0:3167],ct[0:1567],ss[0:31],m[0:31],j[0:31],g[0:63],d[0:31],z[0:31];
    logic [11:0] u[0:1023],v[0:255],uhat[0:1023],what[0:255],w[0:255];

    // Tracking Integers, Counters, and Test Flow Flags
    integer id=0,variant=0,level=4,dklen,ctlen,du,dv;
    integer fwd_index=0,inv_index=0,product_index=0,elapsed=0,groups=0;
    integer max_cycles[2:4],cases=99,variants=5;
    bit checking=0,gaps=0,enc_check=0;
    integer fault=-1,enc_bytes=0,normal_cycles[0:98];
    integer extra_squeezes=0,partial_squeezes=0;
    logic [2:0] prev_dec,prev_hash;
    logic [4:0] prev_enc;

    // -------------------------------------------------------------------------
    // Real-Time Hardware Assertion & Monitoring Logic
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        // Independent cycle tracking and deadlock watchdog
        if (start && ready) elapsed=0;
        else if (!ready) elapsed++;
        if (elapsed>12000) $fatal(1,"Watchdog dec=%0d enc=%0d hash=%0d",dut.dec_state_q,dut.enc_state_q,dut.dec_hash_state_q);

        // Security check: shared secret must not leak prior to done assertion
        if(dut.mode_q==2 && !done && shared_secret !== 0) $fatal(1,"Premature secret output");

        // Verification of encapsulation output during mode switch testing
        if(enc_check && ct_out_valid) begin
            for(int a=0;a<ct_out_bytes;a++) if(ct_out_data[8*a +:8] !== ct[enc_bytes+a]) $fatal(1,"Mode switch encapsulation ciphertext");
            enc_bytes+=ct_out_bytes;
            if(ct_out_last !== (enc_bytes==ctlen)) $fatal(1,"Encapsulation framing");
        end

        // Deep pipeline stage validation during active decapsulation
        if (checking && !(start && ready)) begin
            // Log phase changes for initial test case
            if (id==0 && variant==0) begin
                if (prev_dec!=dut.dec_state_q) $display("DEC phase %0d at %0d",dut.dec_state_q,cycle_cnt);
                if (prev_enc!=dut.enc_state_q) $display("ENC phase %0d at %0d",dut.enc_state_q,cycle_cnt);
                if (prev_hash!=dut.dec_hash_state_q) $display("HASH phase %0d at %0d",dut.dec_hash_state_q,cycle_cnt);
            end

            // Security assertion: Decapsulation must NEVER assert ct_out_valid or emit ciphertext
            if (ct_out_valid) $fatal(1,"Decapsulation leaked ciphertext notification");
            if(ct_out_data !== 0 || ct_out_bytes !== 0 || ct_out_last !== 0) $fatal(1,"Decapsulation ciphertext pins not masked");

            // Squeeze continuation coverage tracking in hash sampler
            if ((dut.hash_sampler_inst.mat_squeeze || dut.hash_sampler_inst.mat_restore_trig) && dut.hash_sampler_inst.core_ready && dut.hash_sampler_inst.block_idx_q==3) begin
                if(dut.hash_sampler_inst.is_last_matrix_poly_q) extra_squeezes++;
                if(dut.hash_sampler_inst.coeff_is_252_q) partial_squeezes++;
            end

            // Verify decompressed ciphertext vectors u and v written to internal buffers
            if (dut.dec_u_write)
                for(int a=0;a<4;a++) if(dut.dec_u_data[12*a +:12] !== u[dut.dec_u_addr*4+a])
                    $fatal(1,"u id=%0d variant=%0d index=%0d got=%0d expected=%0d",id,variant,dut.dec_u_addr*4+a,dut.dec_u_data[12*a +:12],u[dut.dec_u_addr*4+a]);
            if (dut.dec_v_write)
                for(int a=0;a<4;a++) if(dut.dec_v_data[12*a +:12] !== v[dut.dec_v_addr*4+a]) $fatal(1,"v index=%0d",dut.dec_v_addr*4+a);

            // Verify transform engine: forward NTT (uhat) and inverse NTT (w)
            if(dut.dec_compute && dut.ntt_out_valid && dut.ntt_out_ready) begin
                for(int a=0;a<2;a++) begin
                    if(dut.dec_n_inverse) begin
                        if(dut.ntt_out_data[12*a +:12] !== w[inv_index+a]) $fatal(1,"w index=%0d got=%0d expected=%0d",inv_index+a,dut.ntt_out_data[12*a +:12],w[inv_index+a]);
                    end else if(dut.ntt_out_data[12*a +:12] !== uhat[fwd_index+a]) $fatal(1,"uhat index=%0d",fwd_index+a);
                end
                if(dut.dec_n_inverse) inv_index+=2; else fwd_index+=2;
            end

            // Verify pointwise polynomial multiplier product what = s^T * uhat
            if(dut.dec_compute && dut.p3_valid && dut.p3_is_last_col) begin
                for(int a=0;a<4;a++) if(dut.p3_final[12*a +:12] !== what[product_index+a])
                    $fatal(1,"what index=%0d got=%0d expected=%0d",product_index+a,dut.p3_final[12*a +:12],what[product_index+a]);
                product_index+=4;
            end

            // Verify recovered plaintext message m and rejection key j at FO kick-off
            if(dut.dec_kick) begin
                if(fwd_index!=level*256 || inv_index!=256 || product_index!=256) $fatal(1,"Missing stage outputs");
                for(int a=0;a<32;a++) begin
                    if(dut.dec_message[8*a +:8] !== m[a]) $fatal(1,"Recovered m byte=%0d",a);
                    if(dut.dec_reject[8*a +:8] !== j[a]) $fatal(1,"J byte=%0d got=%02x expected=%02x",a,dut.dec_reject[8*a +:8],j[a]);
                end
            end

            // Verify re-encryption hash G output: K' and random coins
            if(dut.enc_state_q==dut.EC_G_WAIT && dut.sampler_digest_valid)
                for(int a=0;a<32;a++) begin
                    if(dut.sampler_digest_out[8*a +:8] !== g[a]) $fatal(1,"G K byte=%0d",a);
                    if(dut.sampler_digest_out_sigma[8*a +:8] !== g[32+a]) $fatal(1,"G coins byte=%0d",a);
                end

            // Track ciphertext comparison groups
            if(dut.enc_emit) groups++;
        end
        prev_dec<=dut.dec_state_q;prev_enc<=dut.enc_state_q;prev_hash<=dut.dec_hash_state_q;
    end

    // -------------------------------------------------------------------------
    // Task: load_case
    // Loads golden test vectors for selected test ID and variant
    // -------------------------------------------------------------------------
    task automatic load_case;
        level=id%3==0 ? 4 : id%3==1 ? 2 : 3;
        k=level;du=level==4 ? 11 : 10;dv=level==4 ? 5 : 4;
        dklen=768*level+96;ctlen=32*(level*du+dv);
        $readmemh($sformatf("dec_%02d_dk.hex",id),dk,0,dklen-1);
        $readmemh($sformatf("dec_%02d_d.hex",id),d);
        $readmemh($sformatf("dec_%02d_z.hex",id),z);
        $readmemh($sformatf("dec_%02d_%0d_ct.hex",id,variant),ct,0,ctlen-1);
        $readmemh($sformatf("dec_%02d_%0d_ss.hex",id,variant),ss);
        $readmemh($sformatf("dec_%02d_%0d_m.hex",id,variant),m);
        $readmemh($sformatf("dec_%02d_%0d_j.hex",id,variant),j);
        $readmemh($sformatf("dec_%02d_%0d_g.hex",id,variant),g);
        $readmemh($sformatf("dec_%02d_%0d_u.hex",id,variant),u,0,level*256-1);
        $readmemh($sformatf("dec_%02d_%0d_v.hex",id,variant),v);
        $readmemh($sformatf("dec_%02d_%0d_uhat.hex",id,variant),uhat,0,level*256-1);
        $readmemh($sformatf("dec_%02d_%0d_what.hex",id,variant),what);
        $readmemh($sformatf("dec_%02d_%0d_w.hex",id,variant),w);
    endtask

    // -------------------------------------------------------------------------
    // Task: send_dk
    // Streams secret key dk in 64-bit lanes over dk_in_* interface with fault injection
    // -------------------------------------------------------------------------
    task automatic send_dk;
        for(int off=0;off<dklen;off+=8) begin
            @(negedge clk);
            if(done) break;
            if(gaps && off%40==0) begin dk_in_valid=0;repeat(7)@(negedge clk);end
            dk_in_valid=1;dk_in_last=off+8==dklen;
            if(fault==1 && off==0) dk_in_last=1;
            if(fault==7 && off+8==dklen) dk_in_last=0;
            for(int a=0;a<8;a++) dk_in_data[8*a +:8]=dk[off+a];
            do @(posedge clk); while(!dk_in_ready && !done);
        end
        @(negedge clk);dk_in_valid=0;dk_in_last=0;
    endtask

    // -------------------------------------------------------------------------
    // Task: send_ct
    // Streams ciphertext groups over ct_in_* interface with fault injection
    // -------------------------------------------------------------------------
    task automatic send_ct;
        int off;
        off=0;
        for(int group=0;group<32*(level+1);group++) begin
            @(negedge clk);ct_in_valid=1;ct_in_data=0;
            if(done) break;
            if(gaps && group%7==0) begin ct_in_valid=0;repeat(11)@(negedge clk);ct_in_valid=1;end
            ct_in_bytes=group<32*level ? du : dv;
            ct_in_last=group==32*(level+1)-1;
            if(fault==2 && group==0) ct_in_last=1;
            if(fault==8 && group==32*(level+1)-1) ct_in_last=0;
            for(int a=0;a<ct_in_bytes;a++) ct_in_data[8*a +:8]=ct[off+a];
            off+=ct_in_bytes;
            if(fault==3 && group==0) ct_in_bytes=1;
            do @(posedge clk); while(!ct_in_ready && !done);
        end
        @(negedge clk);ct_in_valid=0;ct_in_last=0;
    endtask

    // -------------------------------------------------------------------------
    // Task: print_decap_trace
    // Formats and prints C-style NIST Known Answer Test (KAT) trace log
    // -------------------------------------------------------------------------
    task automatic print_decap_trace;
        $display("");
        $display("==================================================================");
        $display(" [C-STYLE KAT TRACE] ML-KEM Decapsulation: Case %0d Variant %0d (k=%0d)", id, variant, level);
        $display("==================================================================");
        $display("[INPUT] k = %0d", level);
        $write("[INPUT] dk = ");
        for (int i = 0; i < dklen; i++) $write("%02x", dk[i]);
        $write("\n");
        $write("[INPUT] ct = ");
        for (int i = 0; i < ctlen; i++) $write("%02x", ct[i]);
        $write("\n");
        $write("[GENERATED] ss = ");
        for (int i = 0; i < 32; i++) $write("%02x", shared_secret[i*8 +: 8]);
        $write("\n");
        $display("==================================================================");
        $display("");
    endtask

    // -------------------------------------------------------------------------
    // Task: run_case
    // Executes full decapsulation, verifies FO comparison, timing invariance, and memory readout
    // -------------------------------------------------------------------------
    task automatic run_case;
        @(negedge clk);mode=2;start=1;
        fwd_index=0;inv_index=0;product_index=0;groups=0;checking=1;
        @(negedge clk);start=0;
        fork
            send_dk();
            send_ct();
            begin
                // Inject unsolicited pin perturbations while busy; must be ignored by DUT
                repeat(20)@(negedge clk);
                k=0;mode=0;start=1;seed_d='1;seed_z='1;enc_message='1;
                repeat(3)@(negedge clk);start=0;
            end
            begin
                wait(done);#0.1;
                if(operation_error) $fatal(1,"Operation error id=%0d variant=%0d cycle=%0d",id,variant,cycle_cnt);
                for(int a=0;a<32;a++) if(shared_secret[8*a +:8] !== ss[a]) $fatal(1,"Secret id=%0d variant=%0d byte=%0d got=%02x expected=%02x",id,variant,a,shared_secret[8*a +:8],ss[a]);
                if(dut.dec_mismatch !== (variant!=0)) $fatal(1,"Comparison result");
                if(groups!=32*(level+1)) $fatal(1,"Incomplete ciphertext comparison");
                if(cycle_cnt!=elapsed) $fatal(1,"Counter differs internal=%0d external=%0d",cycle_cnt,elapsed);
                $display("PASS dec id=%0d variant=%0d k=%0d cycles=%0d",id,variant,level,cycle_cnt);
                print_decap_trace();
                if(!gaps) begin
                    if(cycle_cnt>max_cycles[level]) max_cycles[level]=cycle_cnt;
                    if(cycle_cnt>=4500) $fatal(1,"4500-cycle limit");
                    // Timing side-channel defense check: latency must be identical across valid/invalid ciphertexts
                    if(variant==0) normal_cycles[id]=cycle_cnt;
                    else if(variant<4 && cycle_cnt!=normal_cycles[id]) $fatal(1,"Comparison changed latency");
                end
            end
        join
        checking=0;
        // Verify synchronous memory query readout of established shared secret
        for(int a=0;a<32;a++) begin
            @(negedge clk);mem_rd_en=1;mem_rd_addr=a;
            @(posedge clk);#0.1;
            if(!mem_rd_valid || mem_rd_data !== ss[a]) $fatal(1,"Secret readout byte %0d",a);
        end
        @(negedge clk);mem_rd_en=0;
        // Verify forbidden decapsulation address access returns zero
        for(int a=0;a<4;a++) begin
            @(negedge clk);mem_rd_en=1;mem_rd_is_dk=a[0];mem_rd_addr=a[0] ? 32+a : a;
            @(posedge clk);#0.1;
            if(mem_rd_data !== 0) $fatal(1,"Forbidden decapsulation readout");
        end
        @(negedge clk);mem_rd_en=0;mem_rd_is_dk=1;
    endtask

    // -------------------------------------------------------------------------
    // Task: error_case
    // Injects deliberate malformed inputs and verifies proper rejection
    // -------------------------------------------------------------------------
    task automatic error_case(input integer kind);
        load_case();fault=kind;
        if(kind==4) dk[768*level+32]^=1;                         // Corrupt H(ek)
        if(kind==5) begin dk[384*level]=8'hff;dk[384*level+1]=8'hff;end // Non-canonical public key coeff
        if(kind==6) begin dk[0]=8'hff;dk[1]=8'hff;end             // Non-canonical secret key coeff
        @(negedge clk);mode=2;k=kind==0 ? 1 : level;start=1;     // kind==0 tests invalid security level k=1
        @(negedge clk);start=0;
        fork
            send_dk();send_ct();
            begin wait(done);#0.1;if(!operation_error || shared_secret !== 0) $fatal(1,"Expected error kind=%0d",kind);end
        join
        $display("PASS error kind=%0d k=%0d cycles=%0d",kind,level,cycle_cnt);
        fault=-1;
        load_case();run_case();
    endtask

    // -------------------------------------------------------------------------
    // Task: switch_modes
    // Sequences KeyGen -> Encapsulation -> Decapsulation without intermediate reset
    // -------------------------------------------------------------------------
    task automatic switch_modes;
        load_case();
        for(int a=0;a<32;a++) begin seed_d[8*a +:8]=d[a];seed_z[8*a +:8]=z[a];end
        // 1. Run KeyGen (mode 0)
        @(negedge clk);mode=0;start=1;
        @(negedge clk);start=0;
        wait(done);
        for(int a=0;a<dklen;a++) begin
            @(negedge clk);mem_rd_en=1;mem_rd_is_dk=1;mem_rd_addr=a;
            @(posedge clk);#0.1;
            if(!mem_rd_valid || mem_rd_data !== dk[a]) $fatal(1,"Mode switch KeyGen byte=%0d",a);
        end
        @(negedge clk);mem_rd_en=0;
        // 2. Run Encapsulation (mode 1)
        for(int a=0;a<32;a++)enc_message[8*a +:8]=m[a];
        enc_check=1;enc_bytes=0;mode=1;start=1;
        @(negedge clk);start=0;
        for(int off=384*level;off<768*level+32;off+=8) begin
            @(negedge clk);ek_in_valid=1;ek_in_last=off+8==768*level+32;
            for(int a=0;a<8;a++)ek_in_data[8*a +:8]=dk[off+a];
            do @(posedge clk);while(!ek_in_ready);
        end
        @(negedge clk);ek_in_valid=0;ek_in_last=0;
        wait(done);#0.1;
        if(operation_error || enc_bytes!=ctlen) $fatal(1,"Mode switch encapsulation");
        for(int a=0;a<32;a++)if(shared_secret[8*a +:8] !== ss[a]) $fatal(1,"Mode switch encapsulation secret");
        enc_check=0;
        // 3. Run Decapsulation (mode 2)
        load_case();run_case();
        $display("PASS KeyGen/encapsulation/decapsulation switch k=%0d",level);
    endtask

    // -------------------------------------------------------------------------
    // Task: reset_interruption
    // Injects asynchronous reset during active computation and verifies recovery
    // -------------------------------------------------------------------------
    task automatic reset_interruption(input integer delay_cycles);
        load_case();
        @(negedge clk);mode=2;start=1;
        @(negedge clk);start=0;
        fork: INTERRUPTED
            send_dk();send_ct();
            begin repeat(delay_cycles)@(negedge clk);end
        join_any
        // Wait until the requested phase even if an input producer finished.
        while(cycle_cnt<delay_cycles)@(negedge clk);
        disable INTERRUPTED;
        rst_n=0;dk_in_valid=0;ct_in_valid=0;
        repeat(4)@(negedge clk);rst_n=1;
        repeat(4)@(negedge clk);
        if(!ready || done || ct_out_valid || shared_secret !== 0) $fatal(1,"Reset interruption");
        load_case();run_case();
        $display("PASS reset interruption at %0d",delay_cycles);
    endtask

    // -------------------------------------------------------------------------
    // Main Verification Flow
    // -------------------------------------------------------------------------
    initial begin
        if($value$plusargs("CASES=%d",cases)) begin end
        if($value$plusargs("VARIANTS=%d",variants)) begin end
        for(int a=2;a<=4;a++)max_cycles[a]=0;
        repeat(5)@(negedge clk);rst_n=1;
        // Execute primary regression: 99 cases x 5 variants
        for(id=0;id<cases;id++) for(variant=0;variant<variants;variant++) begin load_case();run_case();end
        if(cases==99 && (extra_squeezes==0 || partial_squeezes==0)) $fatal(1,"Missing SHAKE continuation coverage");
        variant=0;
        // Execute mode switching, backpressure stress, and negative testing
        for(id=0;id<3;id++) begin
            switch_modes();
            gaps=1;load_case();run_case();gaps=0;
            for(int kind=0;kind<9;kind++) error_case(kind);
        end
        // Execute reset interruptions at multiple execution milestones
        id=0;reset_interruption(17);reset_interruption(850);reset_interruption(1800);reset_interruption(3600);
        $display("SHAKE continuation coverage final=%0d partial=%0d",extra_squeezes,partial_squeezes);
        $display("Maximum decapsulation cycles k2=%0d k3=%0d k4=%0d",max_cycles[2],max_cycles[3],max_cycles[4]);
        $display("ALL ML-KEM DECAPSULATION REGRESSIONS PASSED");$finish;
    end
endmodule
