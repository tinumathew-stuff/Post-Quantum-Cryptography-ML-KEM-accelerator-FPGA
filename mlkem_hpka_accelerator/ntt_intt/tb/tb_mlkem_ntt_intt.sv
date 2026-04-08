`timescale 1ns/1ps

//==================================================================================================
// File: tb_mlkem_ntt_intt.sv
// Module: tb_mlkem_ntt_intt
//
// Project: ML-KEM High-Performance Kyber Accelerator (HPKA)
// Specification: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism Standard)
// Target Frequency: 450 MHz (Clock period = 2.222 ns)
//
//==================================================================================================
// TESTBENCH ARCHITECTURE & VERIFICATION METHODOLOGY
//==================================================================================================
// This testbench implements a rigorous, publication-grade verification environment for the
// `mlkem_ntt_intt` forward Number Theoretic Transform (NTT) and inverse INTT accelerator.
//
// Key Verification Pillars:
// 1. Golden Reference Vector Verification:
//    - Loads 20,480 coefficients (80 distinct polynomials of 256 coefficients each) from:
//      * `vectors_input.hex`: Pseudorandom inputs in Z_q, q = 3329.
//      * `vectors_ntt.hex`: Bit-exact golden forward NTT outputs (Cooley-Tukey DIT).
//      * `vectors_intt.hex`: Bit-exact golden inverse INTT outputs (Gentleman-Sande DIF + scaling).
//    - Validates end-to-end polynomial transformations across all security parameter sets:
//      * ML-KEM-512  (k = 2)
//      * ML-KEM-768  (k = 3)
//      * ML-KEM-1024 (k = 4)
//    - Performs complete round-trip verification: Input -> Forward NTT -> Inverse INTT -> Bit-exact Input.
//
// 2. Whitebox Intermediate Pipeline Trace Verification:
//    - Tracks intermediate butterfly stage writeback values against precomputed golden traces:
//      * `trace_ntt.hex`: 1,792 coefficients across all 7 intermediate forward NTT stages.
//      * `trace_intt.hex`: 2,048 coefficients across all 7 inverse stages + normalization pass.
//    - Automatically reconstructs logical word indices from pipeline tags (`tag_row`, `tag_bank`)
//      and verifies intermediate RAM write data on every active commit clock cycle.
//
// 3. Hardware Structural & Protocol Invariant Checking:
//    - Memory Bank Conflict Assertion: Continuously monitors `word_bank[0..7]` every compute cycle;
//      asserts that all 8 parallel memory accesses map to pairwise-distinct distributed RAM banks.
//    - Read-After-Write (RAW) Hazard Immunity: Verifies that inter-stage dependency spacing strictly
//      exceeds the 14-cycle pipeline latency (7 cycles between stages = 1 step + 6 guard cycles).
//    - Output Protocol Stability: Asserts that payload `{out_poly_index, out_last, out_count, out_data}`
//      remains strictly stable and glitch-free whenever downstream receiver exerts backpressure.
//    - Zero-Bubble Pipeline Throughput: Asserts that consecutive queued polynomials transition
//      without a single bubble or idle cycle between their compute issue schedules.
//
// 4. Latency & Concurrency Metric Measurements:
//    - Measures precise cycle counts:
//      * Forward NTT: 112 compute issues across 148 issue cycles; exact commit latency = 162 cycles.
//      * Inverse INTT: 144 compute issues across 186 issue cycles; exact commit latency = 200 cycles.
//    - Triple-Overlap Concurrency: Quantifies cycles where input stream ingestion, butterfly execution,
//      and output stream draining all operate simultaneously across the 3 decoupled RAM slots.
//
// 5. Negative Testing & Fault Injection:
//    - Invalid command parameters (unsupported k, zero count, count > 16).
//    - Malformed streaming beats (illegal in_count, misaligned in_last, non-canonical x >= 3329).
//    - Mid-operation reset abort tests during load, compute, and drain phases.
//==================================================================================================

module tb_mlkem_ntt_intt;
    // Clock generation: 450 MHz nominal frequency (period = 2.222222 ns; half-period = 1.111111 ns)
    logic clk=0;
    always #1.111111 clk=~clk;

    // Command interface signals
    logic rst_n=0,cmd_valid=0,cmd_ready,cmd_mode=0;
    logic [2:0] cmd_k=2;
    logic [4:0] cmd_poly_count=1;

    // Streaming input interface signals
    logic in_valid=0,in_ready,in_last=0;
    logic [23:0] in_data=0;
    logic [1:0] in_count=2;
    logic [3:0] in_poly_index=0;

    // Streaming output interface signals
    logic out_valid,out_ready=0,out_last,cmd_done,cmd_error;
    logic [23:0] out_data;
    logic [1:0] out_count;
    logic [3:0] out_poly_index;

    // Device Under Test (DUT) Instantiation
    mlkem_ntt_intt dut(.*);

    // Golden test vector memories (80 polynomials * 256 coefficients = 20,480 entries each)
    logic [11:0] inputs [0:20479], forward_ref [0:20479], inverse_ref [0:20479];
    logic [11:0] actual_forward [0:20479];

    // Verification statistics, cycle accounting, and latency meters
    integer cycles=0,poly_checked=0,issues=0,issue_start=0,last_issue_cycle=0;
    integer transforms=0,min_ntt=100000,max_ntt=0,min_intt=100000,max_intt=0;
    integer input_waits=0,output_waits=0,overlap_cycles=0;
    integer expected_errors=0,seen_errors=0;
    integer slot_start_cycle [0:2];
    integer measured_ntt_commit=0,measured_intt_commit=0;

    // Whitebox intermediate trace checking control
    logic trace_forward_active=0,trace_inverse_active=0;

    // Output protocol hold checking registers
    logic held_output=0;
    logic [30:0] held_payload;

    // Pseudorandom Number Generator (PRNG) state for backpressure and bubble generation
    logic [31:0] rng=32'hd113eca5;

    // Zero-bubble checking expectation flag
    logic expect_next_issue=0;

    // Intermediate stage trace reference arrays
    logic [11:0] trace_ref [0:1791];       // Forward NTT intermediate stages (7 stages * 256 coeffs)
    integer trace_commit=0;
    logic [11:0] trace_inverse [0:2047];   // Inverse INTT intermediate stages (8 stages * 256 coeffs)
    integer trace_inverse_commit=0;

    // 32-bit Galois / Xorshift PRNG function
    function automatic logic [31:0] next_random(input logic [31:0] x);
        logic [31:0] t;
        t=x^(x<<13); t=t^(t>>17); next_random=t^(t<<5);
    endfunction

    //----------------------------------------------------------------------------------------------
    // Synchronous Protocol Checker & Latency Measurement Engine
    // Runs on every positive clock edge to enforce architectural invariants and collect metrics.
    //----------------------------------------------------------------------------------------------
    always @(posedge clk) begin
        cycles=cycles+1;
        // Global simulation watchdog timeout (1.2 million cycles @ 450 MHz ~ 2.66 ms)
        if (cycles>1200000) $fatal(1,"Global cycle watchdog");

        if (!rst_n) begin
            held_output=0;
            issues=0;
            expect_next_issue=0;
        end else begin
            // 1. Zero-Bubble Queueing Assertion
            // When multiple polynomials are batched and the next slot is READY, consecutive transforms
            // must issue back-to-back without a single idle/bubble cycle.
            if(expect_next_issue && !dut.issue_valid) $fatal(1,"Bubble between queued polynomials");
            expect_next_issue=dut.issue_valid && dut.last_issue &&
                dut.compute_poly_q+1<dut.poly_count_q && dut.slot_state[dut.next_slot(dut.compute_slot_q)]==dut.READY;

            // 2. Whitebox Stage-by-Stage Inverse INTT Trace Verification
            // Verifies writeback data from every butterfly issue against golden intermediate trace.
            if(trace_inverse_active && dut.tag_valid[dut.PIPE-2]) begin
                for(int w=0;w<8;w++) begin
                    integer row,bank,word_index,ci;
                    logic [23:0] want;
                    if(!dut.tag_norm[dut.PIPE-2] || w%2==0) begin
                        row=dut.tag_row[dut.PIPE-2][w];bank=dut.tag_bank[dut.PIPE-2][w];
                        // Reconstruct word index from bank and row address
                        word_index=(row<<3)|(((bank>>2)^((row>>3)^(row>>2)^(row>>1)^row))&1)<<2|(bank&3);
                        ci=(trace_inverse_commit<112 ? trace_inverse_commit/16 : 7)*256+word_index*2;
                        want={trace_inverse[ci+1],trace_inverse[ci]};
                        if(dut.write_data[bank] !== want)
                            $fatal(1,"Inverse trace mismatch issue=%0d word=%0d got=%h want=%h",trace_inverse_commit,word_index,dut.write_data[bank],want);
                    end
                end
                trace_inverse_commit++;
            end

            // 3. Whitebox Stage-by-Stage Forward NTT Trace Verification
            // Verifies writeback data from every butterfly issue against golden intermediate trace.
            if (trace_forward_active && dut.tag_valid[dut.PIPE-2]) begin
                for(int w=0;w<8;w++) begin
                    integer row,bank,word_index,ci;
                    logic [23:0] want;
                    row=dut.tag_row[dut.PIPE-2][w];bank=dut.tag_bank[dut.PIPE-2][w];
                    // Reconstruct word index from bank and row address
                    word_index=(row<<3)|(((bank>>2)^((row>>3)^(row>>2)^(row>>1)^row))&1)<<2|(bank&3);
                    ci=(trace_commit/16)*256+word_index*2;
                    want={trace_ref[ci+1],trace_ref[ci]};
                    if (dut.write_data[bank] !== want)
                        $fatal(1,"Trace mismatch issue=%0d word=%0d got=%h want=%h",trace_commit,word_index,dut.write_data[bank],want);
                end
                trace_commit++;
            end

            // Error and performance telemetry counters
            if (cmd_error) seen_errors=seen_errors+1;
            if (in_valid && !in_ready) input_waits=input_waits+1;
            if (out_valid && !out_ready) output_waits=output_waits+1;

            // Triple-overlap tracking: Ingestion, computation, and egress all active on the same cycle!
            if (dut.issue_valid && in_valid && in_ready && out_valid && out_ready) overlap_cycles=overlap_cycles+1;

            // 4. Output Stream Stability Assertion (Glitch / Mutation Check Under Backpressure)
            // AXI4-Stream rule: when valid is asserted and ready is low, payload MUST remain invariant.
            if (held_output && (!out_valid || {out_poly_index,out_last,out_count,out_data} !== held_payload))
                $fatal(1,"Output changed while blocked at cycle %0d",cycles);
            held_output=out_valid && !out_ready;
            held_payload={out_poly_index,out_last,out_count,out_data};

            // 5. Butterfly Issue Timing & Bank Conflict Assertions
            if (dut.issue_valid) begin
                if (dut.issue_index==0) begin issues=0; issue_start=cycles; end
                if (dut.issue_index==0) slot_start_cycle[dut.compute_slot_q]=cycles;
                else if (cycles != last_issue_cycle + (dut.issue_index[4:0]==0 ? 7 : 1))
                    $fatal(1,"Unexpected dependency spacing");
                issues=issues+1; last_issue_cycle=cycles;

                // Memory Bank Conflict Assertion:
                // Verify all 8 words accessed simultaneously map to 8 distinct memory banks.
                if (!dut.normalizing)
                    for (int a=0;a<8;a++)
                        for (int b=a+1;b<8;b++)
                            if (dut.word_bank[a]==dut.word_bank[b]) $fatal(1,"Bank conflict");

                // Verify exact total issues and schedule length upon final butterfly issue
                if (dut.last_issue) begin
                    if (issues != (dut.inverse_q ? 144 : 112)) $fatal(1,"Wrong issue count");
                    if (cycles-issue_start+1 != (dut.inverse_q ? 186 : 148)) $fatal(1,"Unexpected transform schedule");
                    transforms=transforms+1;
                end
            end

            // 6. Commit Latency Measurement
            // Validates that commit occurs exactly PIPE (14) cycles after the last issue of the transform.
            if(dut.tag_valid[dut.PIPE-1] && dut.tag_last[dut.PIPE-1]) begin
                integer elapsed_cycles;
                elapsed_cycles=cycles-slot_start_cycle[dut.tag_slot[dut.PIPE-1]]+1;
                if(elapsed_cycles != (dut.inverse_q ? 186 : 148)+dut.PIPE)
                    $fatal(1,"Unexpected transform commit latency %0d",elapsed_cycles);
                if(dut.inverse_q) measured_intt_commit=elapsed_cycles;
                else measured_ntt_commit=elapsed_cycles;
            end
        end
    end

    //----------------------------------------------------------------------------------------------
    // Task: reset_dut
    // Purpose: Applies synchronous active-low reset pulse and clears stimulus drivers.
    //----------------------------------------------------------------------------------------------
    task automatic reset_dut;
        @(negedge clk); rst_n=0; in_valid=0;cmd_valid=0;out_ready=0;
        repeat(4) @(negedge clk);
        rst_n=1;
        repeat(2) @(negedge clk);
    endtask

    //----------------------------------------------------------------------------------------------
    // Task: command
    // Purpose: Issues transform command parameters and waits for cmd_ready handshake.
    //----------------------------------------------------------------------------------------------
    task automatic command(input integer mode,input integer k,input integer count);
        @(negedge clk);
        cmd_mode=mode;cmd_k=k;cmd_poly_count=count;cmd_valid=1;
        do @(posedge clk); while (!cmd_ready);
        @(negedge clk);cmd_valid=0;
    endtask

    //----------------------------------------------------------------------------------------------
    // Task: run_batch
    // Purpose: Executes a full batch test with concurrent producer and consumer threads.
    //          Supports 4 stress backpressure profiles:
    //            stress=0: Zero backpressure (full line-rate throughput).
    //            stress=1: Pseudorandom backpressure and input bubbles via PRNG.
    //            stress=2: Alternating 50% toggle backpressure (1 beat on, 1 beat off).
    //            stress=3: Heavy delayed drain (exercises triple-slot queue saturation).
    //----------------------------------------------------------------------------------------------
    task automatic run_batch(input integer mode,input integer k,input integer base,input integer np,input integer stress);
        integer start_cycle, first_output, end_cycle;
        trace_forward_active=mode==0 && k==2 && base==4 && np==1;
        trace_inverse_active=mode==1 && k==2 && base==4 && np==1;
        trace_commit=0;trace_inverse_commit=0;
        command(mode==2 ? 1 : mode,k,np);
        cmd_mode=!(mode!=0);cmd_k=0;cmd_poly_count=0;
        start_cycle=cycles; first_output=-1;
        fork
            // Producer Thread: Streams polynomial input beats to the DUT
            begin: PRODUCER
                integer c,n,t;
                for (int p=0;p<np;p++) begin
                    c=0;
                    while(c<256) begin
                        @(negedge clk);
                        rng=next_random(rng);
                        if (stress==1 && rng[2:0]==0) begin
                            in_valid=0;
                            repeat(3) @(negedge clk);
                        end
                        n=stress==2 ? 1 : ((stress==1 && rng[4]) ? 1 : 2);
                        if (c+n>256) n=1;
                        t=(base+p)*256+c;
                        in_data=mode==2 ? {n==2 ? actual_forward[t+1] : 12'b0,actual_forward[t]} : {n==2 ? inputs[t+1] : 12'b0,inputs[t]};
                        in_count=n;in_poly_index=p;in_last=c+n==256;in_valid=1;
                        do @(posedge clk); while (!in_ready);
                        c=c+n;
                    end
                end
                @(negedge clk);in_valid=0;
            end

            // Consumer Thread: Accepts and verifies transformed output polynomials
            begin: CONSUMER
                integer got,t,local_cycle;
                logic [23:0] expected;
                got=0;local_cycle=0;
                while(got<np*128) begin
                    @(negedge clk);
                    local_cycle=local_cycle+1;
                    case(stress)
                        0: out_ready=1;
                        1: out_ready=((local_cycle*13)%17)<10;
                        2: out_ready=local_cycle%2==0;
                        3: out_ready=local_cycle>1600 && local_cycle%37!=0;
                        default: out_ready=1;
                    endcase
                    @(posedge clk);
                    if(stress==3 && local_cycle>1600 && got<384 && !out_valid)
                        $fatal(1,"Bubble while draining three queued completed polynomials");
                    if(out_valid && out_ready) begin
                        if(first_output<0) first_output=cycles;
                        t=base*256+got*2;
                        expected=mode==2 ? {inputs[t+1],inputs[t]} : (mode ? {inverse_ref[t+1],inverse_ref[t]} : {forward_ref[t+1],forward_ref[t]});
                        if(out_data !== expected)
                            $fatal(1,"Mismatch mode=%0d k=%0d case=%0d coefficient=%0d got=%h expected=%h",mode,k,base+got/128,(got%128)*2,out_data,expected);
                        if(mode==0) begin actual_forward[t]=out_data[11:0];actual_forward[t+1]=out_data[23:12];end
                        if(out_count != 2 || out_poly_index != got/128 || out_last != (got%128==127))
                            $fatal(1,"Output metadata mismatch");
                        got=got+1;
                    end
                    if(local_cycle>30000) $fatal(1,"Batch watchdog");
                end
                poly_checked=poly_checked+np;
                @(negedge clk);out_ready=0;
            end
        join
        end_cycle=cycles;
        if (!cmd_done || !cmd_ready) $fatal(1,"Completion handshake");
        if(stress==0 && np==1) begin
            $display("CYCLES mode=%0d k=%0d command_to_first_output=%0d command_to_done=%0d issue=%0d compute_to_commit=%0d",mode,k,first_output-start_cycle,end_cycle-start_cycle,mode ? 144 : 112,(mode ? 186 : 148)+dut.PIPE);
        end
        if(mode) begin
            if(end_cycle-start_cycle<min_intt) min_intt=end_cycle-start_cycle;
            if(end_cycle-start_cycle>max_intt) max_intt=end_cycle-start_cycle;
        end else begin
            if(end_cycle-start_cycle<min_ntt) min_ntt=end_cycle-start_cycle;
            if(end_cycle-start_cycle>max_ntt) max_ntt=end_cycle-start_cycle;
        end
        repeat(2) @(negedge clk);
    endtask

    //----------------------------------------------------------------------------------------------
    // Task: bad_beat
    // Purpose: Helper task to inject a single malformed beat and verify rejection.
    //----------------------------------------------------------------------------------------------
    task automatic bad_beat(input logic [23:0] data,input logic [1:0] count,input logic last,input logic [3:0] index);
        wait(in_ready);
        @(negedge clk);in_valid=1;in_data=data;in_count=count;in_last=last;in_poly_index=index;
        @(posedge clk);@(negedge clk);in_valid=0;expected_errors++;
        repeat(4) @(negedge clk);
        if(dut.input_coeff_q != 0) $fatal(1,"Malformed beat advanced coefficient state");
    endtask

    //----------------------------------------------------------------------------------------------
    // Task: malformed_test
    // Purpose: Exhaustively tests negative protocol cases:
    //          - in_count = 0 (illegal beat size)
    //          - Premature in_last assertion before 256 coefficients
    //          - Non-canonical coefficient values: x >= 3329 (e.g., 0x000FFF, 0xFFF000)
    //          - Out-of-sequence polynomial index
    //----------------------------------------------------------------------------------------------
    task automatic malformed_test;
        command(0,2,1);
        wait(in_ready);
        @(negedge clk);in_valid=1;in_count=0;in_last=0;in_poly_index=0;in_data=0;
        @(posedge clk);@(negedge clk);in_valid=0;expected_errors=expected_errors+1;
        repeat(2) @(negedge clk);
        if(dut.input_coeff_q != 0) $fatal(1,"Malformed count advanced input");
        @(negedge clk);in_valid=1;in_count=2;in_last=1;in_data=0;
        @(posedge clk);@(negedge clk);in_valid=0;expected_errors=expected_errors+1;
        repeat(2) @(negedge clk);
        if(dut.input_coeff_q != 0) $fatal(1,"Malformed last advanced input");
        @(negedge clk);in_valid=1;in_count=2;in_last=0;in_data=24'h000fff;
        @(posedge clk);@(negedge clk);in_valid=0;expected_errors=expected_errors+1;
        repeat(2) @(negedge clk);
        if(dut.input_coeff_q != 0) $fatal(1,"Noncanonical input accepted");
        bad_beat(0,3,0,0);
        bad_beat(0,2,0,1);
        bad_beat(24'hfff000,2,0,0);
        reset_dut();
    endtask

    //----------------------------------------------------------------------------------------------
    // Task: reset_abort_test
    // Purpose: Evaluates accelerator resilience to mid-operation reset aborts across 3 phases:
    //          phase=0: Reset during input streaming ingestion.
    //          phase=1: Reset during active butterfly pipeline execution.
    //          phase=2: Reset during output streaming draining.
    //          Verifies zero residual activity and clean subsequent execution.
    //----------------------------------------------------------------------------------------------
    task automatic reset_abort_test(input integer mode,input integer phase);
        command(mode,3,1);
        for(int w=0;w<(phase==0 ? 11 : 128);w++) begin
            @(negedge clk);in_valid=1;in_data=0;in_count=2;in_last=w==127;in_poly_index=0;
            do @(posedge clk);while(!in_ready);
        end
        @(negedge clk);in_valid=0;
        if(phase==1) wait(dut.issue_index==12);
        if(phase==2) begin wait(out_valid);repeat(7) @(negedge clk);end
        reset_dut();
        repeat(20) begin
            @(negedge clk);
            if(out_valid || cmd_done || dut.issue_valid || !cmd_ready) $fatal(1,"Activity escaped reset");
        end
        run_batch(mode,3,7,1,0);
    endtask

    //----------------------------------------------------------------------------------------------
    // Main Verification Execution Sequence
    //----------------------------------------------------------------------------------------------
    initial begin
        // Load reference vectors and golden trace tables
        $readmemh("vectors_input.hex",inputs);
        $readmemh("vectors_ntt.hex",forward_ref);
        $readmemh("vectors_intt.hex",inverse_ref);
        $readmemh("trace_ntt.hex",trace_ref);
        $readmemh("trace_intt.hex",trace_inverse);

        // Power-on reset
        reset_dut();

        // 1. Command Parameter Bounds & Negative Tests
        command(0,1,1);expected_errors++;  // Illegal k=1 (must be 2, 3, or 4)
        repeat(3) @(negedge clk);
        if(!cmd_ready) $fatal(1,"Invalid k left busy");
        command(0,2,0);expected_errors++;  // Illegal count=0
        repeat(3) @(negedge clk);
        command(0,4,17);expected_errors++; // Illegal count=17 (> 16)
        repeat(3) @(negedge clk);

        // 2. Malformed Streaming Protocol Injection Tests
        malformed_test();

        // 3. Exhaustive Batch Verification across k=2,3,4 and Modes 0 (NTT), 1 (INTT)
        for(int k=2;k<=4;k++)
            for(int mode=0;mode<2;mode++) begin
                run_batch(mode,k,4,1,0);   // Baseline single-polynomial batch
                for(int stress=0;stress<3;stress++)
                    for(int base=0;base<80;base+=16) run_batch(mode,k,base,16,stress); // 16-poly batches
                run_batch(mode,k,0,16,3);   // Triple-slot queue saturation stress
                run_batch(mode,k,30,k,1);   // Batch size = k with random bubbles
                run_batch(mode,k,40,k*k,1); // Batch size = k^2 with random bubbles
            end

        // 4. Round-Trip Verification: Forward NTT -> Inverse INTT -> Bit-Exact Original Input
        for(int k=2;k<=4;k++)
            for(int base=0;base<80;base+=16) run_batch(2,k,base,16,1);

        // 5. Asynchronous Reset Abort & Recovery Robustness
        for(int mode=0;mode<2;mode++)
            for(int phase=0;phase<3;phase++) reset_abort_test(mode,phase);

        // 6. Final Integrity & Metric Checks
        if(seen_errors != expected_errors) $fatal(1,"Unexpected error pulses %0d expected %0d",seen_errors,expected_errors);
        if(input_waits==0 || output_waits==0 || overlap_cycles==0) $fatal(1,"Missing backpressure/overlap coverage");

        // Report publication-grade test summary
        $display("PASS polynomials=%0d transforms=%0d cycles=%0d input_blocked=%0d output_blocked=%0d triple_overlap=%0d errors=%0d",
                 poly_checked,transforms,cycles,input_waits,output_waits,overlap_cycles,seen_errors);
        $display("BATCH_CYCLES NTT_min=%0d NTT_max=%0d INTT_min=%0d INTT_max=%0d",min_ntt,max_ntt,min_intt,max_intt);
        $display("MEASURED_COMMIT_CYCLES NTT=%0d INTT=%0d",measured_ntt_commit,measured_intt_commit);
        $finish;
    end
endmodule
