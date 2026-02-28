// =============================================================================
// File: field_sub.sv
// Module: field_sub
// Project: ML-KEM High-Performance Cryptographic Hardware Accelerator (HPKA)
// Standard: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Target Frequency: 450 MHz on Modern FPGA Architectures (e.g., AMD UltraScale+)
// =============================================================================
//
// Description:
// ------------
// This module implements a fully pipelined, high-throughput modular subtractor
// computing:
//     out_data = (in_a - in_b) mod Q
// over the finite field Z_q, where Q is the prime modulus defined in NIST
// FIPS 203 for ML-KEM (Q = 3329).
//
// Mathematical Background & Reduction Strategy:
// ----------------------------------------------
// In ML-KEM, all polynomial ring arithmetic is performed modulo q = 3329.
// Input operands in_a and in_b are canonical field elements:
//     in_a, in_b in [0, Q-1], where Q = 3329.
//
// The mathematical modular difference is defined as:
//     (in_a - in_b) mod Q = (in_a >= in_b) ? (in_a - in_b) : (in_a - in_b + Q).
//
// When in_a < in_b, the raw integer difference (in_a - in_b) is negative, lying
// in the range [-(Q-1), -1]. Adding Q maps the negative result back into the
// canonical positive field interval [1, Q-1].
//
// In high-frequency FPGA designs (>= 450 MHz, clock period T <= 2.222 ns),
// performing a magnitude comparison (in_a < in_b) followed sequentially by an
// addition of Q and multiplexing would exceed the critical path timing budget.
//
// To achieve timing closure at 450 MHz, this module employs a DUAL PARALLEL
// CARRY CHAIN architecture:
//
//   1. Carry Chain 1 (Raw Subtraction & Underflow Detection):
//      diff_raw = {1'b0, in_a} - {1'b0, in_b} (13 bits wide).
//      Evaluates the hypothesis that in_a >= in_b.
//      - If in_a >= in_b: The difference is non-negative ([0, Q-1]), and the
//        MSB (diff_raw[DATA_WIDTH], bit 12) is '0'. The correct result is
//        diff_raw[DATA_WIDTH-1:0].
//      - If in_a < in_b: Subtraction underflows, setting the sign/borrow MSB
//        (diff_raw[DATA_WIDTH], bit 12) to '1' in two's complement arithmetic.
//
//   2. Carry Chain 2 (Pre-biased Addition/Subtraction):
//      diff_add = ({1'b0, in_a} + {1'b0, Q}) - {1'b0, in_b} (13 bits wide).
//      Evaluates the alternate hypothesis that in_a < in_b.
//      Since in_a >= 0 and in_b < Q, the term (in_a + Q) is strictly greater
//      than in_b. Thus, diff_add never underflows, and its lower 12 bits
//      represent (in_a - in_b + Q) in [1, Q-1].
//
//   3. Multiplexing:
//      The MSB of Carry Chain 1 (diff_raw[DATA_WIDTH]) is directly used as
//      the select line for a 2:1 multiplexer choosing between diff_add and
//      diff_raw. Both carry chains execute concurrently on hardened FPGA carry
//      structures (e.g., CARRY8 on AMD UltraScale+), completely eliminating
//      serial comparator logic.
//
// Streaming Protocol & 2-Entry Skid Buffer:
// ----------------------------------------
// The module provides an AXI-style valid/ready streaming interface with packet
// framing (in_last / out_last) and features an internal 2-entry skid buffer:
//   - Latency: Exactly 1 clock cycle (when downstream is ready).
//   - Throughput: 100% sustained throughput (1 result per cycle, zero bubbles).
//   - Backpressure Decoupling: in_ready is driven purely by the internal skid
//     status (!skid_valid_q), breaking any combinational backpressure loops
//     between downstream out_ready and upstream in_ready.
//   - Boundary Isolation: out_valid, out_data, and out_last are strictly
//     registered, preventing output path timing degradation across module hierarchies.
//
// =============================================================================

`timescale 1ns/1ps

module field_sub #(
    parameter int DATA_WIDTH = 12,                    // Coefficient bit width (12 bits for Q=3329)
    parameter logic [DATA_WIDTH-1:0] Q = 12'd3329     // FIPS 203 ML-KEM field prime modulus
) (
    input  logic                  clk,       // System clock (target 450 MHz)
    input  logic                  rst_n,     // Asynchronous active-low reset

    // -------------------------------------------------------------------------
    // Input Streaming Interface (Source Side)
    // -------------------------------------------------------------------------
    input  logic                  in_valid,  // Asserted when incoming operands in_a, in_b are valid
    output logic                  in_ready,  // Asserted when module can accept new operand pair
    input  logic [DATA_WIDTH-1:0] in_a,      // Minuend field operand in [0, Q-1]
    input  logic [DATA_WIDTH-1:0] in_b,      // Subtrahend field operand in [0, Q-1]
    input  logic                  in_last,   // Vector framing marker (e.g., end of 256-coeff polynomial)

    // -------------------------------------------------------------------------
    // Output Streaming Interface (Sink Side)
    // -------------------------------------------------------------------------
    output logic                  out_valid, // Asserted when output field element out_data is valid
    input  logic                  out_ready, // Downstream sink ready indicator (backpressure)
    output logic [DATA_WIDTH-1:0] out_data,  // Reduced modular difference (in_a - in_b) mod Q in [0, Q-1]
    output logic                  out_last   // Vector framing marker aligned with out_data
);

    // -------------------------------------------------------------------------
    // Combinatorial Field Subtraction: (a - b) mod Q
    // Dual parallel carry chains for 450 MHz:
    // Chain 1: diff_raw = a - b
    // Chain 2: diff_add = a + Q - b
    // If a < b, diff_raw underflows (bit DATA_WIDTH is 1), selecting diff_add.
    // -------------------------------------------------------------------------

    logic [DATA_WIDTH:0]   diff_raw;  // Carry Chain 1 output: 13-bit difference (in_a - in_b)
    logic [DATA_WIDTH:0]   diff_add;  // Carry Chain 2 output: 13-bit pre-biased sum-diff (in_a + Q - in_b)
    logic [DATA_WIDTH-1:0] comp_res;  // Combinatorial multiplexer output (modular reduced difference)

    // Carry Chain 1: Direct subtraction with MSB zero-extension to detect borrow
    assign diff_raw = {1'b0, in_a} - {1'b0, in_b};

    // Carry Chain 2: Pre-biased subtraction guaranteed not to underflow
    assign diff_add = ({1'b0, in_a} + {1'b0, Q}) - {1'b0, in_b};

    // Fast selection: If bit [DATA_WIDTH] (bit 12) is 1, in_a < in_b (borrow/negative), select diff_add;
    // otherwise in_a >= in_b, select diff_raw.
    assign comp_res = diff_raw[DATA_WIDTH] ? diff_add[DATA_WIDTH-1:0] : diff_raw[DATA_WIDTH-1:0];

    // -------------------------------------------------------------------------
    // Fully Boundary-Registered Streaming Pipeline with 2-Entry Skid Buffer
    // - Isolate all inputs and outputs with boundary registers.
    // - Decoupled in_ready registered backpressure.
    // - Registered out_valid, out_data, out_last outputs.
    // - Zero bubble cycles (100% sustained throughput when sink is ready).
    // -------------------------------------------------------------------------

    // Primary pipeline stage registers (drive module output interface directly)
    logic [DATA_WIDTH-1:0] reg_data_q;   // Registered output data payload
    logic                  reg_last_q;   // Registered output framing flag
    logic                  reg_valid_q;  // Primary stage occupancy / valid status

    // Auxiliary skid buffer registers (absorb pipeline beat during downstream stall)
    logic [DATA_WIDTH-1:0] skid_data_q;  // Skid buffer data payload
    logic                  skid_last_q;  // Skid buffer framing flag
    logic                  skid_valid_q; // Skid stage occupancy / stall flag

    // Drive outputs strictly from primary stage registers to preserve timing margins
    assign out_valid = reg_valid_q;
    assign out_data  = reg_data_q;
    assign out_last  = reg_last_q;

    // Upstream backpressure: accept data whenever the skid buffer has empty capacity.
    // Since in_ready depends only on the skid_valid_q flip-flop, there is zero combinational
    // propagation from out_ready back into in_ready.
    assign in_ready  = !skid_valid_q;

    // -------------------------------------------------------------------------
    // Skid Buffer Control & Pipeline Register Update Process
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Asynchronous reset clears pipeline validity and registers
            reg_valid_q  <= 1'b0;
            reg_data_q   <= '0;
            reg_last_q   <= 1'b0;
            skid_valid_q <= 1'b0;
            skid_data_q  <= '0;
            skid_last_q  <= 1'b0;
        end else begin
            if (skid_valid_q) begin
                // State: Skid buffer holds an element; in_ready was 0, so no new input accepted.
                if (out_ready) begin
                    // Downstream accepted primary register contents; pop stored item from skid buffer
                    reg_data_q   <= skid_data_q;
                    reg_last_q   <= skid_last_q;
                    reg_valid_q  <= 1'b1;
                    skid_valid_q <= 1'b0; // Skid buffer is now emptied, reopening in_ready
                end
            end else begin
                // State: Skid buffer is empty; in_ready was 1
                if (out_ready || !reg_valid_q) begin
                    // Primary stage can accept data (either downstream is accepting or stage is empty)
                    if (in_valid) begin
                        // Latch newly calculated combinatorial modular difference directly into primary stage
                        reg_data_q  <= comp_res;
                        reg_last_q  <= in_last;
                        reg_valid_q <= 1'b1;
                    end else begin
                        // No incoming valid beat; primary stage becomes idle
                        reg_valid_q <= 1'b0;
                    end
                end else begin
                    // State: Downstream is stalled (out_ready == 0) and primary stage is full (reg_valid_q == 1)
                    if (in_valid) begin
                        // Absorb the incoming valid beat into the skid buffer to prevent data loss
                        skid_data_q  <= comp_res;
                        skid_last_q  <= in_last;
                        skid_valid_q <= 1'b1; // Mark skid full; deasserts in_ready next cycle
                    end
                end
            end
        end
    end

endmodule
