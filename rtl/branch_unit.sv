// ============================================================
// branch_unit.sv
// Combinational Branch & Jump Evaluation Unit for the dual-
// issue Superscalar RV32I core.
//
// Responsibilities:
//   1. Evaluate the branch condition for B-type instructions
//      (BEQ, BNE, BLT, BGE, BLTU, BGEU) based on funct3.
//   2. Compute the branch / jump target address.
//   3. Assert branch_taken for unconditional jumps (JAL/JALR)
//      and for conditional branches whose condition is true.
//
// Target address selection:
//   JAL  (is_jalr == 0): pc + sign_ext_imm
//   JALR (is_jalr == 1): (rs1_val + sign_ext_imm) & ~1  (clear LSB per spec)
//   Bxx  (is_jalr == 0): pc + sign_ext_imm  (same formula as JAL)
// ============================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module branch_unit (
  // --- Inputs -------------------------------------------------
  input  logic [2:0]  funct3,       // Branch type (F3_BEQ … F3_BGEU)
  input  logic [31:0] rs1_val,      // Value of source register rs1
  input  logic [31:0] rs2_val,      // Value of source register rs2
  input  logic [31:0] pc,           // Current instruction PC
  input  logic [31:0] imm,          // Sign-extended immediate
  input  logic        is_jalr,      // 1 → JALR (indirect jump via rs1+imm, LSB cleared)

  // --- Outputs ------------------------------------------------
  output logic        branch_taken, // 1 → redirect the PC to branch_target
  output logic [31:0] branch_target // Computed next PC
);

  // -----------------------------------------------------------
  // Internal: condition evaluation
  // -----------------------------------------------------------
  logic cond_taken; // Result of the branch comparison

  always_comb begin : branch_condition
    cond_taken = 1'b0;

    unique case (funct3)
      // BEQ  : branch if rs1 == rs2
      F3_BEQ  : cond_taken = (rs1_val == rs2_val);

      // BNE  : branch if rs1 != rs2
      F3_BNE  : cond_taken = (rs1_val != rs2_val);

      // BLT  : branch if rs1 < rs2  (signed)
      F3_BLT  : cond_taken = ($signed(rs1_val) < $signed(rs2_val));

      // BGE  : branch if rs1 >= rs2 (signed)
      F3_BGE  : cond_taken = ($signed(rs1_val) >= $signed(rs2_val));

      // BLTU : branch if rs1 < rs2  (unsigned)
      F3_BLTU : cond_taken = (rs1_val < rs2_val);

      // BGEU : branch if rs1 >= rs2 (unsigned)
      F3_BGEU : cond_taken = (rs1_val >= rs2_val);

      default : cond_taken = 1'b0;
    endcase
  end : branch_condition

  // -----------------------------------------------------------
  // Branch-taken logic
  //   JALR  → always taken (is_jalr overrides condition)
  //   Bxx   → taken only when condition is true
  // -----------------------------------------------------------
  assign branch_taken = is_jalr | cond_taken;

  // -----------------------------------------------------------
  // Target address computation
  //   JALR : (rs1_val + imm) & ~1
  //   JAL / Bxx : pc + imm
  // -----------------------------------------------------------
  assign branch_target = is_jalr ? ((rs1_val + imm) & ~32'h1)
                                 : (pc + imm);

endmodule : branch_unit
