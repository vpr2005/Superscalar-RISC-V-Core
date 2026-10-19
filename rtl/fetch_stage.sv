// =============================================================================
// fetch_stage.sv
// Dual-issue Superscalar RV32I – Instruction Fetch Stage
//
// Description:
//   Fetches two consecutive 32-bit instructions per cycle from a 64-bit wide
//   instruction memory bus.  The program counter always advances by 8 bytes
//   under normal operation (covering inst0 @ PC and inst1 @ PC+4).
//
//   Control precedence (highest→lowest):
//     1. redirect_valid : branch/jump taken – update PC, squash current pair
//     2. stall          : hazard unit freeze – hold PC and pipeline registers
//     3. normal         : PC += 8, forward fetched instructions
//
//   Pipeline register (fetch → decode):
//     Holds pc_out_0/1, instr_out_0/1, valid_0/1 and is gated by stall/flush.
//
// Interface:
//   clk            – system clock (rising-edge triggered)
//   rst_n          – synchronous active-low reset
//   stall          – freeze PC and fetch pipeline register
//   flush          – invalidate pipeline register (redirect without full stall)
//   redirect_valid – a branch/jump has resolved; load redirect_target into PC
//   redirect_target– target PC supplied by the branch unit
//   imem_rdata     – 64-bit instruction memory read data
//                    bits[31: 0] → instruction 0 (lower address)
//                    bits[63:32] → instruction 1 (upper address)
//   imem_addr      – fetch address driven to instruction memory (8-byte aligned)
//   pc_out_0       – registered PC of instruction 0
//   pc_out_1       – registered PC of instruction 1 (= pc_out_0 + 4)
//   instr_out_0    – registered instruction word 0
//   instr_out_1    – registered instruction word 1
//   valid_0        – instruction 0 valid flag (registered)
//   valid_1        – instruction 1 valid flag; de-asserted on redirect/flush
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module fetch_stage (
    input  logic        clk,
    input  logic        rst_n,

    // ── Hazard / Redirect Controls ──────────────────────────────────────────
    input  logic        stall,           // Freeze PC + pipeline register
    input  logic        flush,           // Invalidate pipeline register only

    input  logic        redirect_valid,  // Branch/jump redirect request
    input  logic [31:0] redirect_target, // Resolved target PC

    // ── Instruction Memory Interface ────────────────────────────────────────
    input  logic [63:0] imem_rdata,      // 64-bit fetch data from I-memory
    output logic [31:0] imem_addr,       // Fetch address (8-byte aligned)

    // ── Fetch → Decode Pipeline Registers ──────────────────────────────────
    output logic [31:0] pc_out_0,        // PC of instruction slot 0
    output logic [31:0] pc_out_1,        // PC of instruction slot 1 (pc_out_0+4)
    output logic [31:0] instr_out_0,     // Instruction word 0
    output logic [31:0] instr_out_1,     // Instruction word 1
    output logic        valid_0,         // Slot 0 valid
    output logic        valid_1          // Slot 1 valid
);

    // =========================================================================
    // Internal Signals
    // =========================================================================

    // Program counter register
    logic [31:0] pc_reg;

    // Next-state PC (combinational)
    logic [31:0] pc_next;

    // =========================================================================
    // PC Next-State Logic (combinational)
    // =========================================================================
    always_comb begin
        if (redirect_valid) begin
            // Branch/jump taken: redirect PC to resolved target.
            // The redirect_target is expected to be 32-bit aligned; the fetch
            // address is then aligned down to 8 bytes by the imem_addr driver.
            pc_next = redirect_target;
        end else if (stall) begin
            // Hazard hold: keep current PC
            pc_next = pc_reg;
        end else begin
            // Normal two-instruction advance: +8 bytes
            pc_next = pc_reg + 32'd8;
        end
    end

    // =========================================================================
    // PC Register – Synchronous Active-Low Reset
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc_reg <= 32'h0000_0000;   // Reset vector
        end else begin
            pc_reg <= pc_next;
        end
    end

    // =========================================================================
    // Instruction Memory Address
    // The address is driven combinationally from the *current* PC so that the
    // memory can respond with data that is captured into the pipeline register
    // on the following rising edge.  Bit[2] is forced to 0 to align to 8 bytes.
    // =========================================================================
    assign imem_addr = {pc_reg[31:3], 3'b000};  // 8-byte aligned fetch address

    // =========================================================================
    // Fetch Pipeline Register – Fetch → Decode
    // =========================================================================
    // Registered outputs isolate the fetch stage from the decode stage and
    // provide the standard pipeline cut-point.
    //
    // Reset/Flush/Redirect behaviour:
    //   • rst_n=0      : all outputs cleared, both valid flags de-asserted
    //   • flush=1      : both valid flags de-asserted (bubble injected)
    //   • redirect_valid: de-assert valid_1 for the *currently fetching* pair;
    //                    the redirect affects the *next* cycle's PC, so the pair
    //                    already presented by imem_rdata this cycle is squashed
    //                    entirely (both valids cleared) because it was fetched
    //                    from the wrong path.
    //   • stall=1      : pipeline register holds (no update)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // ── Synchronous Reset ──────────────────────────────────────────
            pc_out_0    <= 32'd0;
            pc_out_1    <= 32'd0;
            instr_out_0 <= 32'd0;
            instr_out_1 <= 32'd0;
            valid_0     <= 1'b0;
            valid_1     <= 1'b0;

        end else if (flush || redirect_valid) begin
            // ── Flush / Redirect: inject bubble ────────────────────────────
            // Squash both slots so the decode stage sees no valid instructions
            // while the pipeline drains and refills from the new PC.
            pc_out_0    <= 32'd0;
            pc_out_1    <= 32'd0;
            instr_out_0 <= 32'd0;
            instr_out_1 <= 32'd0;
            valid_0     <= 1'b0;
            valid_1     <= 1'b0;

        end else if (!stall) begin
            // ── Normal Advance ─────────────────────────────────────────────
            pc_out_0    <= pc_reg;           // Slot 0 PC  = current fetch PC
            pc_out_1    <= pc_reg + 32'd4;   // Slot 1 PC  = PC + 4
            instr_out_0 <= imem_rdata[31:0]; // Instruction 0 from lower 32 bits
            instr_out_1 <= imem_rdata[63:32];// Instruction 1 from upper 32 bits
            valid_0     <= 1'b1;
            valid_1     <= 1'b1;

        end
        // else: stall=1 → pipeline register retains its current value
    end

endmodule : fetch_stage
