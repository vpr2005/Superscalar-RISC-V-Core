// ============================================================
// superscalar_core.sv
// Top-Level Integration of the Dual-Issue Superscalar RV32I
// Processor Core.
//
// Pipeline stages wired together:
//   FETCH -> DECODE -> ISSUE_QUEUE -> EX0/EX1 -> MEM -> WB (ROB commit)
//
// External Interfaces:
//   - 64-bit Instruction Memory bus (dual instruction fetch)
//   - 32-bit Data Memory bus (load/store)
// ============================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module superscalar_core (
  input  logic          clk,
  input  logic          rst_n,

  // ---- Instruction Memory Interface ----
  output logic [31:0]   imem_addr,     // Fetch address (8-byte aligned)
  input  logic [63:0]   imem_rdata,    // Two instructions: [31:0]=inst0, [63:32]=inst1

  // ---- Data Memory Interface ----
  output logic [31:0]   dmem_addr,     // Memory address
  output logic          dmem_rd_en,    // Load enable
  input  logic [31:0]   dmem_rdata,    // Load data from memory
  output logic          dmem_wr_en,    // Store enable
  output logic [3:0]    dmem_byte_en,  // Byte enables for store
  output logic [31:0]   dmem_wdata     // Store data
);

  // ===========================================================
  // Internal Signal Declarations
  // ===========================================================

  // --- Fetch -> Decode pipeline ---
  logic [31:0]    fetch_pc0,   fetch_pc1;
  logic [31:0]    fetch_inst0, fetch_inst1;
  logic           fetch_valid0, fetch_valid1;

  // --- Decode outputs ---
  decoded_instr_t dec_out_0, dec_out_1;
  logic           intra_dep;

  // --- ROB Tagging for Dispatch ---
  logic [3:0]     rob_tail;
  decoded_instr_t disp_instr_0, disp_instr_1;

  always_comb begin
    disp_instr_0 = dec_out_0;
    disp_instr_0.rob_tag = rob_tail;

    disp_instr_1 = dec_out_1;
    disp_instr_1.rob_tag = (dec_out_0.valid) ? (rob_tail + 4'd1) : rob_tail;
  end

  // --- Register File signals ---
  logic [31:0]    rf_rs1_0, rf_rs2_0;
  logic [31:0]    rf_rs1_1, rf_rs2_1;

  // --- Hazard/Control signals ---
  logic           stall_fetch, stall_decode, stall_issue;
  logic           flush_fetch, flush_decode, flush_issue;
  logic           redirect_valid;
  logic [31:0]    redirect_target;

  // --- Issue Queue outputs ---
  decoded_instr_t iq_instr_0, iq_instr_1;
  logic [31:0]    iq_op1_0, iq_op2_0;
  logic [31:0]    iq_op1_1, iq_op2_1;
  logic           iq_valid_0, iq_valid_1;
  logic           iq_full, iq_empty;

  // --- EX stage results ---
  ex_result_t     ex0_result, ex1_result;
  logic           branch_taken_0, branch_taken_1;
  logic [31:0]    branch_target_0, branch_target_1;

  // --- MEM stage pipeline registers ---
  ex_result_t     mem0_result, mem1_result;

  // --- Load/Store Unit ---
  logic [31:0]    lsu_load_result;
  logic [31:0]    lsu_mem_addr;
  logic [3:0]     lsu_byte_en;
  logic [31:0]    lsu_wdata;
  logic           lsu_mem_req;
  logic           lsu_misalign;

  // --- Forwarding Unit resolved values ---
  logic [31:0]    fwd_op1_0, fwd_op2_0;
  logic [31:0]    fwd_op1_1, fwd_op2_1;
  logic           fwd_sel_1_0, fwd_sel_2_0;
  logic           fwd_sel_1_1, fwd_sel_2_1;

  // --- ROB Commit -> Register File writeback ---
  logic [4:0]     commit_rd_0,   commit_rd_1;
  logic [31:0]    commit_data_0, commit_data_1;
  logic           commit_we_0,   commit_we_1;
  logic           rob_full, rob_empty;

  // ===========================================================
  // Stage 1: Fetch
  // ===========================================================
  fetch_stage u_fetch (
    .clk              (clk),
    .rst_n            (rst_n),
    .stall            (stall_fetch),
    .flush            (flush_fetch),
    .redirect_valid   (redirect_valid),
    .redirect_target  (redirect_target),
    .imem_rdata       (imem_rdata),
    .imem_addr        (imem_addr),
    .pc_out_0         (fetch_pc0),
    .pc_out_1         (fetch_pc1),
    .instr_out_0      (fetch_inst0),
    .instr_out_1      (fetch_inst1),
    .valid_0          (fetch_valid0),
    .valid_1          (fetch_valid1)
  );

  // ===========================================================
  // Stage 2: Decode
  // ===========================================================
  decode_stage u_decode (
    .clk              (clk),
    .rst_n            (rst_n),
    .stall            (stall_decode),
    .flush            (flush_decode),
    .pc_in_0          (fetch_pc0),
    .pc_in_1          (fetch_pc1),
    .instr_in_0       (fetch_inst0),
    .instr_in_1       (fetch_inst1),
    .valid_in_0       (fetch_valid0),
    .valid_in_1       (fetch_valid1),
    .dec_out_0        (dec_out_0),
    .dec_out_1        (dec_out_1),
    .intra_dep        (intra_dep)
  );

  // ===========================================================
  // Register File (4R / 2W)
  // ===========================================================
  regfile u_regfile (
    .clk              (clk),
    .rst_n            (rst_n),
    .rs1_addr_0       (dec_out_0.rs1),
    .rs2_addr_0       (dec_out_0.rs2),
    .rs1_addr_1       (dec_out_1.rs1),
    .rs2_addr_1       (dec_out_1.rs2),
    .rs1_data_0       (rf_rs1_0),
    .rs2_data_0       (rf_rs2_0),
    .rs1_data_1       (rf_rs1_1),
    .rs2_data_1       (rf_rs2_1),
    .we_0             (commit_we_0),
    .we_1             (commit_we_1),
    .rd_addr_0        (commit_rd_0),
    .rd_addr_1        (commit_rd_1),
    .rd_data_0        (commit_data_0),
    .rd_data_1        (commit_data_1)
  );

  // ===========================================================
  // Reorder Buffer (In-Order Commit Tracker)
  // ===========================================================
  reorder_buffer #(
    .ROB_DEPTH(16)
  ) u_rob (
    .clk           (clk),
    .rst_n         (rst_n),
    .flush         (flush_issue),
    .rob_tail      (rob_tail),
    .disp_instr_0  (disp_instr_0),
    .disp_instr_1  (disp_instr_1),
    .disp_valid_0  (disp_instr_0.valid & ~stall_issue),
    .disp_valid_1  (disp_instr_1.valid & ~stall_issue),
    .complete_0    (ex0_result),
    .complete_1    (ex1_result),
    .commit_rd_0   (commit_rd_0),
    .commit_data_0 (commit_data_0),
    .commit_we_0   (commit_we_0),
    .commit_rd_1   (commit_rd_1),
    .commit_data_1 (commit_data_1),
    .commit_we_1   (commit_we_1),
    .rob_full      (rob_full),
    .rob_empty     (rob_empty)
  );

  // ===========================================================
  // Stage 3: Issue Queue (Dynamic Instruction Window)
  // ===========================================================
  issue_queue #(
    .IQ_DEPTH(8)
  ) u_iq (
    .clk              (clk),
    .rst_n            (rst_n),
    .flush            (flush_issue),
    .enq_instr_0      (disp_instr_0),
    .enq_instr_1      (disp_instr_1),
    .enq_valid_0      (disp_instr_0.valid & ~stall_issue & ~rob_full),
    .enq_valid_1      (disp_instr_1.valid & ~stall_issue & ~rob_full),
    .rf_op1_0         (rf_rs1_0),
    .rf_op2_0         (rf_rs2_0),
    .rf_op1_1         (rf_rs1_1),
    .rf_op2_1         (rf_rs2_1),
    .ex0_result       (ex0_result),
    .ex1_result       (ex1_result),
    .mem0_result      (mem0_result),
    .mem1_result      (mem1_result),
    .issue_instr_0    (iq_instr_0),
    .issue_instr_1    (iq_instr_1),
    .issue_op1_0      (iq_op1_0),
    .issue_op2_0      (iq_op2_0),
    .issue_op1_1      (iq_op1_1),
    .issue_op2_1      (iq_op2_1),
    .issue_valid_0    (iq_valid_0),
    .issue_valid_1    (iq_valid_1),
    .iq_full          (iq_full),
    .iq_empty         (iq_empty)
  );

  // ===========================================================
  // Operand Forwarding Network
  // ===========================================================
  forwarding_unit u_fwd (
    .rs1_0         (iq_instr_0.rs1),
    .rs2_0         (iq_instr_0.rs2),
    .rs1_1         (iq_instr_1.rs1),
    .rs2_1         (iq_instr_1.rs2),
    .mem0_result   (mem0_result),
    .mem1_result   (mem1_result),
    .commit_we_0   (commit_we_0),
    .commit_rd_0   (commit_rd_0),
    .commit_data_0 (commit_data_0),
    .commit_we_1   (commit_we_1),
    .commit_rd_1   (commit_rd_1),
    .commit_data_1 (commit_data_1),
    .rf_op1_0      (iq_op1_0),
    .rf_op2_0      (iq_op2_0),
    .rf_op1_1      (iq_op1_1),
    .rf_op2_1      (iq_op2_1),
    .fwd_op1_0     (fwd_op1_0),
    .fwd_op2_0     (fwd_op2_0),
    .fwd_op1_1     (fwd_op1_1),
    .fwd_op2_1     (fwd_op2_1),
    .fwd_sel_op1_0 (fwd_sel_1_0),
    .fwd_sel_op2_0 (fwd_sel_2_0),
    .fwd_sel_op1_1 (fwd_sel_1_1),
    .fwd_sel_op2_1 (fwd_sel_2_1)
  );

  // ===========================================================
  // Stage 4: Execution — Pipeline 0 (ALU + Branch)
  // ===========================================================
  logic [31:0]  ex0_alu_result;
  logic         ex0_zero, ex0_neg, ex0_ovf;
  logic [31:0]  ex0_opa, ex0_opb;

  assign ex0_opa = (iq_instr_0.use_pc)  ? iq_instr_0.pc  : fwd_op1_0;
  assign ex0_opb = (iq_instr_0.use_imm) ? iq_instr_0.imm : fwd_op2_0;

  alu u_alu0 (
    .alu_op        (iq_instr_0.alu_op),
    .op_a          (ex0_opa),
    .op_b          (ex0_opb),
    .result        (ex0_alu_result),
    .zero_flag     (ex0_zero),
    .neg_flag      (ex0_neg),
    .overflow_flag (ex0_ovf)
  );

  branch_unit u_bru0 (
    .funct3        (iq_instr_0.funct3),
    .rs1_val       (fwd_op1_0),
    .rs2_val       (fwd_op2_0),
    .pc            (iq_instr_0.pc),
    .imm           (iq_instr_0.imm),
    .is_jalr       (iq_instr_0.is_jalr),
    .branch_taken  (branch_taken_0),
    .branch_target (branch_target_0)
  );

  always_comb begin
    ex0_result.valid         = iq_valid_0;
    ex0_result.reg_write     = iq_instr_0.reg_write;
    ex0_result.rd            = iq_instr_0.rd;
    ex0_result.mem_read      = iq_instr_0.mem_read;
    ex0_result.branch_taken  = branch_taken_0 & iq_valid_0 & (iq_instr_0.cat == CAT_BRANCH || iq_instr_0.is_jal || iq_instr_0.is_jalr);
    ex0_result.branch_target = branch_target_0;
    ex0_result.rob_tag       = iq_instr_0.rob_tag;

    if (iq_instr_0.is_jal || iq_instr_0.is_jalr)
      ex0_result.result = iq_instr_0.pc + 32'd4;
    else
      ex0_result.result = ex0_alu_result;
  end

  // ===========================================================
  // Stage 4: Execution — Pipeline 1 (ALU + LSU)
  // ===========================================================
  logic [31:0]  ex1_alu_result;
  logic         ex1_zero, ex1_neg, ex1_ovf;
  logic [31:0]  ex1_opa, ex1_opb;

  assign ex1_opa = (iq_instr_1.use_pc)  ? iq_instr_1.pc  : fwd_op1_1;
  assign ex1_opb = (iq_instr_1.use_imm) ? iq_instr_1.imm : fwd_op2_1;

  alu u_alu1 (
    .alu_op        (iq_instr_1.alu_op),
    .op_a          (ex1_opa),
    .op_b          (ex1_opb),
    .result        (ex1_alu_result),
    .zero_flag     (ex1_zero),
    .neg_flag      (ex1_neg),
    .overflow_flag (ex1_ovf)
  );

  branch_unit u_bru1 (
    .funct3        (iq_instr_1.funct3),
    .rs1_val       (fwd_op1_1),
    .rs2_val       (fwd_op2_1),
    .pc            (iq_instr_1.pc),
    .imm           (iq_instr_1.imm),
    .is_jalr       (iq_instr_1.is_jalr),
    .branch_taken  (branch_taken_1),
    .branch_target (branch_target_1)
  );

  load_store_unit u_lsu (
    .clk           (clk),
    .rst_n         (rst_n),
    .base_addr     (fwd_op1_1),
    .offset        (iq_instr_1.imm),
    .funct3        (iq_instr_1.funct3),
    .is_load       (iq_instr_1.mem_read  & iq_valid_1),
    .is_store      (iq_instr_1.mem_write & iq_valid_1),
    .store_data    (fwd_op2_1),
    .mem_addr      (lsu_mem_addr),
    .mem_byte_en   (lsu_byte_en),
    .mem_wdata     (lsu_wdata),
    .mem_rdata     (dmem_rdata),
    .load_result   (lsu_load_result),
    .mem_req_valid (lsu_mem_req),
    .misalign_err  (lsu_misalign)
  );

  assign dmem_addr    = lsu_mem_addr;
  assign dmem_rd_en   = iq_instr_1.mem_read  & iq_valid_1;
  assign dmem_wr_en   = iq_instr_1.mem_write & iq_valid_1;
  assign dmem_byte_en = lsu_byte_en;
  assign dmem_wdata   = lsu_wdata;

  always_comb begin
    ex1_result.valid         = iq_valid_1;
    ex1_result.reg_write     = iq_instr_1.reg_write;
    ex1_result.rd            = iq_instr_1.rd;
    ex1_result.mem_read      = iq_instr_1.mem_read;
    ex1_result.branch_taken  = branch_taken_1 & iq_valid_1 & (iq_instr_1.cat == CAT_BRANCH || iq_instr_1.is_jal || iq_instr_1.is_jalr);
    ex1_result.branch_target = branch_target_1;
    ex1_result.rob_tag       = iq_instr_1.rob_tag;

    if (iq_instr_1.is_jal || iq_instr_1.is_jalr)
      ex1_result.result = iq_instr_1.pc + 32'd4;
    else if (iq_instr_1.mem_read)
      ex1_result.result = lsu_load_result;
    else
      ex1_result.result = ex1_alu_result;
  end

  // ===========================================================
  // MEM Stage Pipeline Register (EX -> MEM -> WB)
  // ===========================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_issue) begin
      mem0_result <= '0;
      mem1_result <= '0;
    end else begin
      mem0_result <= ex0_result;
      mem1_result <= ex1_result;
    end
  end

  // ===========================================================
  // Hazard Unit
  // ===========================================================
  hazard_unit u_hazard (
    .dec_0           (dec_out_0),
    .dec_1           (dec_out_1),
    .ex0_result      (ex0_result),
    .ex1_result      (ex1_result),
    .branch_taken_0  (ex0_result.branch_taken),
    .branch_taken_1  (ex1_result.branch_taken),
    .branch_target_0 (ex0_result.branch_target),
    .branch_target_1 (ex1_result.branch_target),
    .stall_fetch     (stall_fetch),
    .stall_decode    (stall_decode),
    .stall_issue     (stall_issue),
    .flush_fetch     (flush_fetch),
    .flush_decode    (flush_decode),
    .flush_issue     (flush_issue),
    .redirect_valid  (redirect_valid),
    .redirect_target (redirect_target)
  );

endmodule
