// ============================================================
// reorder_buffer.sv
// In-order commit buffer for the dual-issue Superscalar RV32I
// core. Ensures precise architectural state on branch
// mispredictions by committing results to the architectural
// register file in strict program order.
// ============================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module reorder_buffer #(
  parameter int ROB_DEPTH = 16  // Must be power of 2
)(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          flush,         // Flush all entries (branch mispredict)

  // --- Tag Distribution Interface (to Dispatch) ---
  output logic [$clog2(ROB_DEPTH)-1:0] rob_tail,

  // --- Dispatch Interface (from Decode / Dispatch) ---
  input  decoded_instr_t disp_instr_0, // Instruction 0 to track
  input  decoded_instr_t disp_instr_1, // Instruction 1 to track
  input  logic           disp_valid_0, // Dispatch valid for slot 0
  input  logic           disp_valid_1, // Dispatch valid for slot 1

  // --- Completion Interface (from Execution units) ---
  input  ex_result_t     complete_0,   // EX pipeline 0 result with rob_tag
  input  ex_result_t     complete_1,   // EX pipeline 1 result with rob_tag

  // --- Commit Interface (to Register File) ---
  output logic [4:0]     commit_rd_0,   // Writeback destination 0
  output logic [31:0]    commit_data_0, // Writeback data 0
  output logic           commit_we_0,   // Writeback enable 0
  output logic [4:0]     commit_rd_1,   // Writeback destination 1
  output logic [31:0]    commit_data_1, // Writeback data 1
  output logic           commit_we_1,   // Writeback enable 1

  // --- Status ---
  output logic           rob_full,
  output logic           rob_empty
);

  localparam int PTR_W = $clog2(ROB_DEPTH);

  typedef struct packed {
    logic [4:0]  rd;          // Destination register
    logic [31:0] result;      // Computed result
    logic        reg_write;   // Does this instr write a register?
    logic        complete;    // Has execution finished?
    logic        valid;       // Entry occupies a slot
    logic [31:0] pc;          // PC of instruction (for tracking)
  } rob_entry_t;

  rob_entry_t rob [ROB_DEPTH-1:0];

  logic [PTR_W-1:0] head;         // Oldest entry (commit pointer)
  logic [PTR_W-1:0] tail;         // Next free slot (dispatch pointer)
  logic [PTR_W:0]   count;        // Number of valid entries

  assign rob_tail  = tail;
  assign rob_full  = (count >= (ROB_DEPTH - 2));
  assign rob_empty = (count == '0);

  // -----------------------------------------------------------
  // Commit Conditions (combinational)
  // -----------------------------------------------------------
  logic commit_0, commit_1;

  assign commit_0 = rob[head].valid && rob[head].complete;
  assign commit_1 = commit_0 && rob[head + PTR_W'(1)].valid && rob[head + PTR_W'(1)].complete;

  // -----------------------------------------------------------
  // Combinational Commit Output to Register File
  // -----------------------------------------------------------
  always_comb begin
    commit_we_0   = 1'b0;
    commit_rd_0   = 5'd0;
    commit_data_0 = 32'd0;

    commit_we_1   = 1'b0;
    commit_rd_1   = 5'd0;
    commit_data_1 = 32'd0;

    if (commit_0) begin
      commit_we_0   = rob[head].reg_write && (rob[head].rd != 5'd0);
      commit_rd_0   = rob[head].rd;
      commit_data_0 = rob[head].result;
    end

    if (commit_1) begin
      commit_we_1   = rob[head + PTR_W'(1)].reg_write && (rob[head + PTR_W'(1)].rd != 5'd0);
      commit_rd_1   = rob[head + PTR_W'(1)].rd;
      commit_data_1 = rob[head + PTR_W'(1)].result;
    end
  end

  // -----------------------------------------------------------
  // Sequential Updates: Dispatch, Completion, and Commit
  // -----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) begin
      head  <= '0;
      tail  <= '0;
      count <= '0;
      for (int i = 0; i < ROB_DEPTH; i++) begin
        rob[i] <= '0;
      end
    end else begin
      int num_commits;
      int num_dispatched;

      num_commits = 0;
      num_dispatched = 0;

      // --- 1. Completion update by ROB tag ---
      if (complete_0.valid) begin
        rob[complete_0.rob_tag].result   <= complete_0.result;
        rob[complete_0.rob_tag].complete <= 1'b1;
      end

      if (complete_1.valid) begin
        rob[complete_1.rob_tag].result   <= complete_1.result;
        rob[complete_1.rob_tag].complete <= 1'b1;
      end

      // --- 2. Dispatch (allocation at tail) ---
      if (disp_valid_0 && !rob_full) begin
        rob[tail].rd        <= disp_instr_0.rd;
        rob[tail].result    <= 32'd0;
        rob[tail].reg_write <= disp_instr_0.reg_write;
        rob[tail].complete  <= 1'b0;
        rob[tail].valid     <= 1'b1;
        rob[tail].pc        <= disp_instr_0.pc;
        num_dispatched++;
      end

      if (disp_valid_1 && !rob_full) begin
        automatic logic [PTR_W-1:0] t1;
        t1 = (disp_valid_0) ? (tail + PTR_W'(1)) : tail;
        rob[t1].rd        <= disp_instr_1.rd;
        rob[t1].result    <= 32'd0;
        rob[t1].reg_write <= disp_instr_1.reg_write;
        rob[t1].complete  <= 1'b0;
        rob[t1].valid     <= 1'b1;
        rob[t1].pc        <= disp_instr_1.pc;
        num_dispatched++;
      end

      tail <= tail + PTR_W'(num_dispatched);

      // --- 3. Commit advance ---
      if (commit_1) begin
        rob[head].valid              <= 1'b0;
        rob[head + PTR_W'(1)].valid  <= 1'b0;
        head <= head + PTR_W'(2);
        num_commits = 2;
      end else if (commit_0) begin
        rob[head].valid <= 1'b0;
        head <= head + PTR_W'(1);
        num_commits = 1;
      end

      count <= count + (PTR_W + 1)'(num_dispatched) - (PTR_W + 1)'(num_commits);
    end
  end

endmodule : reorder_buffer
