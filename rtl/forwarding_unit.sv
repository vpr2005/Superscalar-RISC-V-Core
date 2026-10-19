// =============================================================================
// File        : forwarding_unit.sv
// Project     : Dual-Issue Superscalar RV32I Core
// Description : Combinational operand forwarding network for both pipelines.
//
//   Forwarding priority (highest to lowest):
//     1. EX stage  – pipeline 0  (ex0_result)   ← newest result
//     2. EX stage  – pipeline 1  (ex1_result)
//     3. MEM stage – pipeline 0  (mem0_result)
//     4. MEM stage – pipeline 1  (mem1_result)
//     5. Register file read                      ← fallback
//
//   The unit resolves all four source operands in parallel:
//     - op1 / op2 for pipeline 0   (indexed _0)
//     - op1 / op2 for pipeline 1   (indexed _1)
//
//   Outputs:
//     fwd_sel_opX_Y  – 1 when a forwarded value is available
//     fwd_opX_Y      – the resolved value (forwarded OR regfile, always valid)
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module forwarding_unit (
    // ── Source register addresses ────────────────────────────────────────────
    input  logic [4:0]    rs1_0,         // Pipeline 0, source reg 1
    input  logic [4:0]    rs2_0,         // Pipeline 0, source reg 2
    input  logic [4:0]    rs1_1,         // Pipeline 1, source reg 1
    input  logic [4:0]    rs2_1,         // Pipeline 1, source reg 2

    // ── Forwarding buses (registered pipeline stages only) ───────────────────
    input  ex_result_t    mem0_result,   // MEM stage, pipeline 0 (cycle N-1)
    input  ex_result_t    mem1_result,   // MEM stage, pipeline 1 (cycle N-1)
    input  logic          commit_we_0,   // WB/commit stage, port 0
    input  logic [4:0]    commit_rd_0,
    input  logic [31:0]   commit_data_0,
    input  logic          commit_we_1,   // WB/commit stage, port 1
    input  logic [4:0]    commit_rd_1,
    input  logic [31:0]   commit_data_1,

    // ── Register file / Issue queue fallback reads ───────────────────────────
    input  logic [31:0]   rf_op1_0,     // Regfile/IQ rs1 for pipeline 0
    input  logic [31:0]   rf_op2_0,     // Regfile/IQ rs2 for pipeline 0
    input  logic [31:0]   rf_op1_1,     // Regfile/IQ rs1 for pipeline 1
    input  logic [31:0]   rf_op2_1,     // Regfile/IQ rs2 for pipeline 1

    // ── Resolved operand outputs ─────────────────────────────────────────────
    output logic [31:0]   fwd_op1_0,    // Resolved op1 for pipeline 0
    output logic [31:0]   fwd_op2_0,    // Resolved op2 for pipeline 0
    output logic [31:0]   fwd_op1_1,    // Resolved op1 for pipeline 1
    output logic [31:0]   fwd_op2_1,    // Resolved op2 for pipeline 1

    // ── Forward-select flags (1 = forwarded value used) ──────────────────────
    output logic          fwd_sel_op1_0,
    output logic          fwd_sel_op2_0,
    output logic          fwd_sel_op1_1,
    output logic          fwd_sel_op2_1
);

    // =========================================================================
    // Internal combinational signals
    // =========================================================================
    logic [31:0] fwd_val_op1_0, fwd_val_op2_0;
    logic [31:0] fwd_val_op1_1, fwd_val_op2_1;

    // ─── Pipeline 0, Operand 1 (rs1_0) ──────────────────────────────────────
    always_comb begin
        fwd_sel_op1_0 = 1'b0;
        fwd_val_op1_0 = rf_op1_0;

        if (rs1_0 == 5'd0) begin
            fwd_sel_op1_0 = 1'b0;
            fwd_val_op1_0 = 32'd0;
        end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == rs1_0)) begin
            fwd_sel_op1_0 = 1'b1;
            fwd_val_op1_0 = mem1_result.result;
        end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == rs1_0)) begin
            fwd_sel_op1_0 = 1'b1;
            fwd_val_op1_0 = mem0_result.result;
        end else if (commit_we_1 && (commit_rd_1 != 5'd0) && (commit_rd_1 == rs1_0)) begin
            fwd_sel_op1_0 = 1'b1;
            fwd_val_op1_0 = commit_data_1;
        end else if (commit_we_0 && (commit_rd_0 != 5'd0) && (commit_rd_0 == rs1_0)) begin
            fwd_sel_op1_0 = 1'b1;
            fwd_val_op1_0 = commit_data_0;
        end
    end

    // ─── Pipeline 0, Operand 2 (rs2_0) ──────────────────────────────────────
    always_comb begin
        fwd_sel_op2_0 = 1'b0;
        fwd_val_op2_0 = rf_op2_0;

        if (rs2_0 == 5'd0) begin
            fwd_sel_op2_0 = 1'b0;
            fwd_val_op2_0 = 32'd0;
        end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == rs2_0)) begin
            fwd_sel_op2_0 = 1'b1;
            fwd_val_op2_0 = mem1_result.result;
        end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == rs2_0)) begin
            fwd_sel_op2_0 = 1'b1;
            fwd_val_op2_0 = mem0_result.result;
        end else if (commit_we_1 && (commit_rd_1 != 5'd0) && (commit_rd_1 == rs2_0)) begin
            fwd_sel_op2_0 = 1'b1;
            fwd_val_op2_0 = commit_data_1;
        end else if (commit_we_0 && (commit_rd_0 != 5'd0) && (commit_rd_0 == rs2_0)) begin
            fwd_sel_op2_0 = 1'b1;
            fwd_val_op2_0 = commit_data_0;
        end
    end

    // ─── Pipeline 1, Operand 1 (rs1_1) ──────────────────────────────────────
    always_comb begin
        fwd_sel_op1_1 = 1'b0;
        fwd_val_op1_1 = rf_op1_1;

        if (rs1_1 == 5'd0) begin
            fwd_sel_op1_1 = 1'b0;
            fwd_val_op1_1 = 32'd0;
        end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == rs1_1)) begin
            fwd_sel_op1_1 = 1'b1;
            fwd_val_op1_1 = mem1_result.result;
        end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == rs1_1)) begin
            fwd_sel_op1_1 = 1'b1;
            fwd_val_op1_1 = mem0_result.result;
        end else if (commit_we_1 && (commit_rd_1 != 5'd0) && (commit_rd_1 == rs1_1)) begin
            fwd_sel_op1_1 = 1'b1;
            fwd_val_op1_1 = commit_data_1;
        end else if (commit_we_0 && (commit_rd_0 != 5'd0) && (commit_rd_0 == rs1_1)) begin
            fwd_sel_op1_1 = 1'b1;
            fwd_val_op1_1 = commit_data_0;
        end
    end

    // ─── Pipeline 1, Operand 2 (rs2_1) ──────────────────────────────────────
    always_comb begin
        fwd_sel_op2_1 = 1'b0;
        fwd_val_op2_1 = rf_op2_1;

        if (rs2_1 == 5'd0) begin
            fwd_sel_op2_1 = 1'b0;
            fwd_val_op2_1 = 32'd0;
        end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == rs2_1)) begin
            fwd_sel_op2_1 = 1'b1;
            fwd_val_op2_1 = mem1_result.result;
        end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == rs2_1)) begin
            fwd_sel_op2_1 = 1'b1;
            fwd_val_op2_1 = mem0_result.result;
        end else if (commit_we_1 && (commit_rd_1 != 5'd0) && (commit_rd_1 == rs2_1)) begin
            fwd_sel_op2_1 = 1'b1;
            fwd_val_op2_1 = commit_data_1;
        end else if (commit_we_0 && (commit_rd_0 != 5'd0) && (commit_rd_0 == rs2_1)) begin
            fwd_sel_op2_1 = 1'b1;
            fwd_val_op2_1 = commit_data_0;
        end
    end

    // =========================================================================
    // Output assignment
    // =========================================================================
    assign fwd_op1_0 = fwd_val_op1_0;
    assign fwd_op2_0 = fwd_val_op2_0;
    assign fwd_op1_1 = fwd_val_op1_1;
    assign fwd_op2_1 = fwd_val_op2_1;

endmodule : forwarding_unit
