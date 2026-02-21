// =============================================================================
// File: field_add.sv
// Module: field_add
// Project: ML-KEM High-Performance Cryptographic Hardware Accelerator (HPKA)
// Standard: NIST FIPS 203 (Module-Lattice-Based Key-Encapsulation Mechanism)
// Target Frequency: 450 MHz on Modern FPGA Architectures (e.g., AMD UltraScale+)
// =============================================================================
//
// Description:
// ------------
// This module implements a fully pipelined, high-throughput modular adder
// computing:
//     out_data = (in_a + in_b) mod Q
// over the finite field Z_q, where Q is the prime modulus defined in NIST
// FIPS 203 for ML-KEM (Q = 3329).
//
// Mathematical Background & Reduction Strategy:
// ----------------------------------------------
// In ML-KEM, all polynomial ring arithmetic is performed modulo q = 3329.
// Input operands in_a and in_b are canonical field elements:
//     in_a, in_b in [0, Q-1], where Q = 3329.
// The unreduced arithmetic sum satisfies:
//     S_raw = in_a + in_b in [0, 2Q - 2] = [0, 6656].
// Since S_raw < 2Q, the modular reduction requires at most a single subtraction of Q:
//     (in_a + in_b) mod Q = (S_raw >= Q) ? (S_raw - Q) : S_raw.
//
// Traditional sequential implementations compute the 13-bit sum, compare the
// result against Q (or subtract Q), and conditionally select the reduced value.
// In high-frequency FPGA designs (>= 450 MHz, clock period T <= 2.222 ns),
// this cascaded adder-comparator-multiplexer path typically violates setup
// timing across logic fabric routing.
//
// To guarantee timing closure at 450 MHz, this module utilizes a DUAL PARALLEL
// CARRY CHAIN architecture:
//
//   1. Carry Chain 1 (Raw Addition):
//      sum_raw = in_a + in_b (13 bits).
//      Represents the hypothesis that in_a + in_b < Q.
//
//   2. Carry Chain 2 (Biased Subtractive Addition):
//      Instead of an explicit comparator or two's complement subtractor in series,
//      we evaluate in parallel:
//          sum_sub = in_a + in_b + Q_COMP
//      where:
//          Q_COMP = 2^(DATA_WIDTH+1) - Q = 2^13 - 3329 = 8192 - 3329 = 4863.
//
//      Proof of Selection Mechanism:
//      - If (in_a + in_b) >= Q:
//            sum_sub = (in_a + in_b) + (8192 - Q) >= Q + 8192 - Q = 8192 = 2^13.
//        Thus, bit 13 (sum_sub[DATA_WIDTH+1]) overflows to '1'.
//        Furthermore, modulo 2^13:
//            sum_sub[11:0] = (in_a + in_b + 8192 - Q) mod 4096 = (in_a + in_b - Q).
//        Since 0 <= in_a + in_b - Q < Q = 3329 < 4096, sum_sub[11:0] exactly matches
//        the reduced field element.
//
//      - If (in_a + in_b) < Q:
//            sum_sub = (in_a + in_b) + (8192 - Q) < Q + 8192 - Q = 8192 = 2^13.
//        Thus, bit 13 (sum_sub[DATA_WIDTH+1]) remains '0'.
//        The unreduced sum sum_raw[11:0] is selected.
//
// Both additions map directly to dedicated hardened DSP/CARRY primitives (e.g.,
// CARRY8 on AMD UltraScale+) and execute in parallel with identical latency.
// A single-level 2:1 LUT multiplexer steered by sum_sub[13] provides the result.
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

module field_add #(
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
    input  logic [DATA_WIDTH-1:0] in_a,      // First canonical field operand in [0, Q-1]
    input  logic [DATA_WIDTH-1:0] in_b,      // Second canonical field operand in [0, Q-1]
    input  logic                  in_last,   // Vector framing marker (e.g., end of 256-coeff polynomial)

    // -------------------------------------------------------------------------
    // Output Streaming Interface (Sink Side)
    // -------------------------------------------------------------------------
    output logic                  out_valid, // Asserted when output field element out_data is valid
    input  logic                  out_ready, // Downstream sink ready indicator (backpressure)
    output logic [DATA_WIDTH-1:0] out_data,  // Reduced modular sum (in_a + in_b) mod Q in [0, Q-1]
    output logic                  out_last   // Vector framing marker aligned with out_data
);

    // -------------------------------------------------------------------------
    // Combinatorial Field Addition: (a + b) mod Q
    // Dual parallel carry chains for 450 MHz:
    // Chain 1: sum_raw = a + b
    // Chain 2: sum_sub = a + b + (8192 - Q) = a + b + 4863
    // If sum_raw >= Q, sum_sub overflows into bit (DATA_WIDTH+1), selecting sum_sub.
    // -------------------------------------------------------------------------
    
    // Constant complementary offset: 2^(DATA_WIDTH+1) - Q = 8192 - 3329 = 4863
    // Used to detect overflow >= Q using standard adder carry-out.
    localparam logic [DATA_WIDTH+1:0] Q_COMP = (1'b1 << (DATA_WIDTH+1)) - {2'b00, Q};

    logic [DATA_WIDTH:0]   sum_raw;   // Carry Chain 1 output: 13-bit sum (a + b)
    logic [DATA_WIDTH+1:0] sum_sub;   // Carry Chain 2 output: 14-bit biased sum (a + b + Q_COMP)
    logic [DATA_WIDTH-1:0] comp_res;  // Combinatorial multiplexer output (modular reduced sum)

    // Carry Chain 1: Unreduced arithmetic sum in [0, 6656]
    assign sum_raw  = {1'b0, in_a} + {1'b0, in_b};

    // Carry Chain 2: Biased sum in [4863, 11519]
    assign sum_sub  = {2'b00, in_a} + {2'b00, in_b} + Q_COMP;

    // Fast selection: If bit [DATA_WIDTH+1] (bit 13) is 1, sum >= Q, select sum_sub; else sum_raw
    assign comp_res = sum_sub[DATA_WIDTH+1] ? sum_sub[DATA_WIDTH-1:0] : sum_raw[DATA_WIDTH-1:0];

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
                        // Latch newly calculated combinatorial modular sum directly into primary stage
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
