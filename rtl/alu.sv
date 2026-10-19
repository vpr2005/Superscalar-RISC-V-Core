// ============================================================
// alu.sv
// 32-bit Arithmetic Logic Unit for the dual-issue Superscalar
// RV32I core.  Purely combinational — no clock or reset.
//
// Operations encoded in alu_op_e from riscv_pkg.
// Covers all RV32I integer ops + branch comparators + LUI.
//
// Flags:
//   zero_flag     — result is all-zeros
//   neg_flag      — result[31] (MSB), negative in 2's complement
//   overflow_flag — signed arithmetic overflow (ADD / SUB only)
// ============================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module alu (
  // --- Inputs -------------------------------------------------
  input  alu_op_e     alu_op,       // Operation select
  input  logic [31:0] op_a,         // Operand A (rs1 or PC for AUIPC/JAL)
  input  logic [31:0] op_b,         // Operand B (rs2 or sign-extended imm)

  // --- Outputs ------------------------------------------------
  output logic [31:0] result,       // ALU result
  output logic        zero_flag,    // 1 when result == 0
  output logic        neg_flag,     // 1 when result[31] == 1
  output logic        overflow_flag // 1 on signed ADD/SUB overflow
);

  // -----------------------------------------------------------
  // Shared adder / subtractor
  // -----------------------------------------------------------
  logic [31:0] add_result;
  logic [31:0] sub_result;
  logic        add_overflow;
  logic        sub_overflow;

  assign add_result = op_a + op_b;
  assign sub_result = op_a - op_b;

  // Signed overflow: ADD — both same sign, result differs
  assign add_overflow = (~op_a[31] & ~op_b[31] &  add_result[31]) |
                        ( op_a[31] &  op_b[31] & ~add_result[31]);
  // Signed overflow: SUB — operands differ in sign, result ≠ op_a sign
  assign sub_overflow = (~op_a[31] &  op_b[31] &  sub_result[31]) |
                        ( op_a[31] & ~op_b[31] & ~sub_result[31]);

  // -----------------------------------------------------------
  // Main ALU: unique case on alu_op_e enum
  // -----------------------------------------------------------
  always_comb begin : alu_core
    result        = 32'h0;
    overflow_flag = 1'b0;

    unique case (alu_op)
      // ---- Arithmetic -----------------------------------------
      ALU_ADD    : begin result = add_result; overflow_flag = add_overflow; end
      ALU_SUB    : begin result = sub_result; overflow_flag = sub_overflow; end

      // ---- Bitwise --------------------------------------------
      ALU_AND    : result = op_a & op_b;
      ALU_OR     : result = op_a | op_b;
      ALU_XOR    : result = op_a ^ op_b;

      // ---- Shifts (lower 5 bits of op_b = shamt) --------------
      ALU_SLL    : result = op_a << op_b[4:0];
      ALU_SRL    : result = op_a >> op_b[4:0];
      ALU_SRA    : result = $signed(op_a) >>> op_b[4:0];

      // ---- Set-Less-Than --------------------------------------
      ALU_SLT    : result = ($signed(op_a) < $signed(op_b)) ? 32'd1 : 32'd0;
      ALU_SLTU   : result = (op_a < op_b)                   ? 32'd1 : 32'd0;

      // ---- Branch Comparators (result used as taken flag) -----
      ALU_SEQ    : result = (op_a == op_b)                   ? 32'd1 : 32'd0;
      ALU_SNE    : result = (op_a != op_b)                   ? 32'd1 : 32'd0;
      ALU_SGE    : result = ($signed(op_a) >= $signed(op_b)) ? 32'd1 : 32'd0;
      ALU_SGEU   : result = (op_a >= op_b)                   ? 32'd1 : 32'd0;

      // ---- LUI: pass immediate through (B operand) ------------
      ALU_COPY_B : result = op_b;

      // ---- No-op / unused -------------------------------------
      ALU_NOP    : result = 32'h0;

      default    : result = 32'h0;
    endcase
  end : alu_core

  // -----------------------------------------------------------
  // Status flags
  // -----------------------------------------------------------
  assign zero_flag = (result == 32'h0);
  assign neg_flag  = result[31];

endmodule : alu
