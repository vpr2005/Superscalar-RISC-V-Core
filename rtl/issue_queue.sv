// =============================================================================
// File        : issue_queue.sv
// Project     : Dual-Issue Superscalar RV32I Core
// Description : Dynamic instruction window / issue queue with scoreboarding
//               and in-flight dependency tracking.
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module issue_queue #(
    parameter int IQ_DEPTH = 8          // Power of 2 (e.g. 8)
) (
    input  logic            clk,
    input  logic            rst_n,      // Synchronous active-low reset
    input  logic            flush,      // Flush on branch mispredict

    // ── Enqueue interface (from Decode stage) ────────────────────────────────
    input  decoded_instr_t  enq_instr_0,
    input  decoded_instr_t  enq_instr_1,
    input  logic            enq_valid_0,
    input  logic            enq_valid_1,

    // ── Register file reads (captured at decode) ─────────────────────────────
    input  logic [31:0]     rf_op1_0,   // rs1 value for enq_instr_0
    input  logic [31:0]     rf_op2_0,   // rs2 value for enq_instr_0
    input  logic [31:0]     rf_op1_1,   // rs1 value for enq_instr_1
    input  logic [31:0]     rf_op2_1,   // rs2 value for enq_instr_1

    // ── Forwarding / wakeup buses ────────────────────────────────────────────
    input  ex_result_t      ex0_result,
    input  ex_result_t      ex1_result,
    input  ex_result_t      mem0_result,
    input  ex_result_t      mem1_result,

    // ── Issue interface (to Execution stage) ─────────────────────────────────
    output decoded_instr_t  issue_instr_0,
    output decoded_instr_t  issue_instr_1,
    output logic [31:0]     issue_op1_0,
    output logic [31:0]     issue_op2_0,
    output logic [31:0]     issue_op1_1,
    output logic [31:0]     issue_op2_1,
    output logic            issue_valid_0,
    output logic            issue_valid_1,

    // ── Backpressure ─────────────────────────────────────────────────────────
    output logic            iq_full,
    output logic            iq_empty
);

    localparam int PTR_W = $clog2(IQ_DEPTH);

    // Issue-queue entry record
    typedef struct packed {
        logic            valid;         // Entry is occupied
        decoded_instr_t  instr;         // Decoded instruction
        logic [31:0]     op1;           // Captured / forwarded operand 1
        logic [31:0]     op2;           // Captured / forwarded operand 2
        logic            src1_rdy;      // Operand 1 is ready
        logic            src2_rdy;      // Operand 2 is ready
    } iq_entry_t;

    iq_entry_t  queue     [IQ_DEPTH-1:0];
    iq_entry_t  queue_nxt [IQ_DEPTH-1:0];

    logic [PTR_W-1:0] head, head_nxt;
    logic [PTR_W-1:0] tail, tail_nxt;
    logic [PTR_W:0]   count, count_nxt;

    assign iq_full  = (count >= (IQ_DEPTH - 1));
    assign iq_empty = (count == '0);

    // =========================================================================
    // Helper: Check if an in-flight instruction in the queue produces register rs
    // =========================================================================
    function automatic logic check_inflight_producer (
        input logic [4:0] rs
    );
        logic found;
        found = 1'b0;
        if (rs != 5'd0) begin
            for (int k = 0; k < IQ_DEPTH; k++) begin
                if (queue_nxt[k].valid && queue_nxt[k].instr.reg_write && (queue_nxt[k].instr.rd == rs)) begin
                    found = 1'b1;
                end
            end
        end
        return found;
    endfunction

    // =========================================================================
    // Helper: Check if an unissued instruction older than target_idx writes to rs
    // =========================================================================
    function automatic logic has_older_producer (
        input logic [PTR_W-1:0] target_idx,
        input logic [4:0]       rs
    );
        logic found;
        found = 1'b0;
        if (rs != 5'd0) begin
            for (int k = 0; k < IQ_DEPTH; k++) begin
                automatic logic [PTR_W-1:0] curr;
                curr = PTR_W'((int'(head_nxt) + k) % IQ_DEPTH);
                if (curr == target_idx) break; // Reached target, stop
                if (queue_nxt[curr].valid && queue_nxt[curr].instr.reg_write && (queue_nxt[curr].instr.rd == rs)) begin
                    found = 1'b1;
                    break;
                end
            end
        end
        return found;
    endfunction

    // =========================================================================
    // Combinational next-state logic
    // =========================================================================
    logic [PTR_W-1:0] issue_idx  [0:1];
    logic             do_issue_0;
    logic             do_issue_1;
    logic             found_0, found_1;
    logic             slot0_is_mem;

    always_comb begin : comb_logic
        int i;

        for (i = 0; i < IQ_DEPTH; i++) begin
            queue_nxt[i] = queue[i];
        end
        head_nxt  = head;
        tail_nxt  = tail;
        count_nxt = count;

        issue_instr_0 = '0;
        issue_instr_1 = '0;
        issue_op1_0   = '0;
        issue_op2_0   = '0;
        issue_op1_1   = '0;
        issue_op2_1   = '0;
        issue_valid_0 = 1'b0;
        issue_valid_1 = 1'b0;
        issue_idx[0]  = '0;
        issue_idx[1]  = '0;
        do_issue_0    = 1'b0;
        do_issue_1    = 1'b0;
        found_0       = 1'b0;
        found_1       = 1'b0;
        slot0_is_mem  = 1'b0;

        // =====================================================================
        // STEP 1 – ISSUE SELECTION (Dual-Issue to EX0 and EX1)
        // Check registered queue entries (ready before this cycle began).
        // =====================================================================
        // ─ Issue slot 0: find oldest ready NON-MEMORY instruction (EX0 has ALU + BRU)
        for (i = 0; i < IQ_DEPTH; i++) begin
            automatic logic [PTR_W-1:0] idx;
            idx = PTR_W'((int'(head) + i) % IQ_DEPTH);

            if (!found_0 && queue[idx].valid &&
                queue[idx].src1_rdy && queue[idx].src2_rdy &&
                !(queue[idx].instr.mem_read | queue[idx].instr.mem_write)) begin
                issue_instr_0  = queue[idx].instr;
                issue_op1_0    = queue[idx].op1;
                issue_op2_0    = queue[idx].op2;
                issue_valid_0  = 1'b1;
                issue_idx[0]   = idx;
                found_0        = 1'b1;
            end
        end

        // ─ Issue slot 1: find oldest ready instruction (EX1 has ALU + LSU)
        for (i = 0; i < IQ_DEPTH; i++) begin
            automatic logic [PTR_W-1:0] idx;
            idx = PTR_W'((int'(head) + i) % IQ_DEPTH);

            if (!found_1 &&
                (!found_0 || (idx != issue_idx[0])) &&
                queue[idx].valid &&
                queue[idx].src1_rdy && queue[idx].src2_rdy) begin
                issue_instr_1  = queue[idx].instr;
                issue_op1_1    = queue[idx].op1;
                issue_op2_1    = queue[idx].op2;
                issue_valid_1  = 1'b1;
                issue_idx[1]   = idx;
                found_1        = 1'b1;
            end
        end

        do_issue_0 = found_0;
        do_issue_1 = found_1;

        if (do_issue_0) queue_nxt[issue_idx[0]].valid = 1'b0;
        if (do_issue_1) queue_nxt[issue_idx[1]].valid = 1'b0;

        // ── Advance head pointer ──────────────────────────────────────────────
        begin
            automatic logic [PTR_W-1:0] h = head;
            automatic logic [PTR_W:0]   c = count;

            if (do_issue_0) c = c - 1;
            if (do_issue_1) c = c - 1;

            for (i = 0; i < IQ_DEPTH; i++) begin
                if (c > 0 && !queue_nxt[h].valid) begin
                    h = PTR_W'((int'(h) + 1) % IQ_DEPTH);
                end
            end

            head_nxt  = h;
            count_nxt = c;
        end

        // =====================================================================
        // STEP 2 – WAKEUP REMAINING ENTRIES FOR NEXT CYCLE
        // =====================================================================
        for (i = 0; i < IQ_DEPTH; i++) begin
            if (queue_nxt[i].valid) begin
                // Wake up source 1 only if no older unissued instruction in queue writes to rs1
                if (!queue_nxt[i].src1_rdy && (queue_nxt[i].instr.rs1 != 5'd0) && !has_older_producer(PTR_W'(i), queue_nxt[i].instr.rs1)) begin
                    if (ex1_result.valid && ex1_result.reg_write && (ex1_result.rd == queue_nxt[i].instr.rs1)) begin
                        queue_nxt[i].op1      = ex1_result.result;
                        queue_nxt[i].src1_rdy = 1'b1;
                    end else if (ex0_result.valid && ex0_result.reg_write && (ex0_result.rd == queue_nxt[i].instr.rs1)) begin
                        queue_nxt[i].op1      = ex0_result.result;
                        queue_nxt[i].src1_rdy = 1'b1;
                    end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == queue_nxt[i].instr.rs1)) begin
                        queue_nxt[i].op1      = mem1_result.result;
                        queue_nxt[i].src1_rdy = 1'b1;
                    end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == queue_nxt[i].instr.rs1)) begin
                        queue_nxt[i].op1      = mem0_result.result;
                        queue_nxt[i].src1_rdy = 1'b1;
                    end
                end

                // Wake up source 2 only if no older unissued instruction in queue writes to rs2
                if (!queue_nxt[i].src2_rdy && (queue_nxt[i].instr.rs2 != 5'd0) && !has_older_producer(PTR_W'(i), queue_nxt[i].instr.rs2)) begin
                    if (ex1_result.valid && ex1_result.reg_write && (ex1_result.rd == queue_nxt[i].instr.rs2)) begin
                        queue_nxt[i].op2      = ex1_result.result;
                        queue_nxt[i].src2_rdy = 1'b1;
                    end else if (ex0_result.valid && ex0_result.reg_write && (ex0_result.rd == queue_nxt[i].instr.rs2)) begin
                        queue_nxt[i].op2      = ex0_result.result;
                        queue_nxt[i].src2_rdy = 1'b1;
                    end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == queue_nxt[i].instr.rs2)) begin
                        queue_nxt[i].op2      = mem1_result.result;
                        queue_nxt[i].src2_rdy = 1'b1;
                    end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == queue_nxt[i].instr.rs2)) begin
                        queue_nxt[i].op2      = mem0_result.result;
                        queue_nxt[i].src2_rdy = 1'b1;
                    end
                end
            end
        end

        // =====================================================================
        // STEP 3 – ENQUEUE WITH READINESS RESOLUTION
        // =====================================================================
        if (enq_valid_0 && (count_nxt < IQ_DEPTH)) begin
            logic [31:0] op1_v, op2_v;
            logic        s1_rdy, s2_rdy;

            // Resolve operand 1
            if (enq_instr_0.rs1 == 5'd0 || !enq_instr_0.use_rs1) begin
                op1_v = rf_op1_0; s1_rdy = 1'b1;
            end else if (check_inflight_producer(enq_instr_0.rs1)) begin
                op1_v = 32'd0; s1_rdy = 1'b0; // Wait for in-flight instruction to finish
            end else if (ex1_result.valid && ex1_result.reg_write && (ex1_result.rd == enq_instr_0.rs1)) begin
                op1_v = ex1_result.result; s1_rdy = 1'b1;
            end else if (ex0_result.valid && ex0_result.reg_write && (ex0_result.rd == enq_instr_0.rs1)) begin
                op1_v = ex0_result.result; s1_rdy = 1'b1;
            end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == enq_instr_0.rs1)) begin
                op1_v = mem1_result.result; s1_rdy = 1'b1;
            end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == enq_instr_0.rs1)) begin
                op1_v = mem0_result.result; s1_rdy = 1'b1;
            end else begin
                op1_v = rf_op1_0; s1_rdy = 1'b1;
            end

            // Resolve operand 2
            if (enq_instr_0.rs2 == 5'd0 || !enq_instr_0.use_rs2) begin
                op2_v = rf_op2_0; s2_rdy = 1'b1;
            end else if (check_inflight_producer(enq_instr_0.rs2)) begin
                op2_v = 32'd0; s2_rdy = 1'b0;
            end else if (ex1_result.valid && ex1_result.reg_write && (ex1_result.rd == enq_instr_0.rs2)) begin
                op2_v = ex1_result.result; s2_rdy = 1'b1;
            end else if (ex0_result.valid && ex0_result.reg_write && (ex0_result.rd == enq_instr_0.rs2)) begin
                op2_v = ex0_result.result; s2_rdy = 1'b1;
            end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == enq_instr_0.rs2)) begin
                op2_v = mem1_result.result; s2_rdy = 1'b1;
            end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == enq_instr_0.rs2)) begin
                op2_v = mem0_result.result; s2_rdy = 1'b1;
            end else begin
                op2_v = rf_op2_0; s2_rdy = 1'b1;
            end

            queue_nxt[tail_nxt].valid    = 1'b1;
            queue_nxt[tail_nxt].instr    = enq_instr_0;
            queue_nxt[tail_nxt].op1      = op1_v;
            queue_nxt[tail_nxt].op2      = op2_v;
            queue_nxt[tail_nxt].src1_rdy = s1_rdy;
            queue_nxt[tail_nxt].src2_rdy = s2_rdy;

            tail_nxt  = PTR_W'((int'(tail_nxt) + 1) % IQ_DEPTH);
            count_nxt = count_nxt + 1;
        end

        if (enq_valid_1 && (count_nxt < IQ_DEPTH)) begin
            logic [31:0] op1_v, op2_v;
            logic        s1_rdy, s2_rdy;

            // Resolve operand 1 (check enq_instr_0 dependency first)
            if (enq_instr_1.rs1 == 5'd0 || !enq_instr_1.use_rs1) begin
                op1_v = rf_op1_1; s1_rdy = 1'b1;
            end else if (enq_valid_0 && enq_instr_0.reg_write && (enq_instr_0.rd != 5'd0) && (enq_instr_0.rd == enq_instr_1.rs1)) begin
                op1_v = 32'd0; s1_rdy = 1'b0; // Depends on enq_instr_0!
            end else if (check_inflight_producer(enq_instr_1.rs1)) begin
                op1_v = 32'd0; s1_rdy = 1'b0;
            end else if (ex1_result.valid && ex1_result.reg_write && (ex1_result.rd == enq_instr_1.rs1)) begin
                op1_v = ex1_result.result; s1_rdy = 1'b1;
            end else if (ex0_result.valid && ex0_result.reg_write && (ex0_result.rd == enq_instr_1.rs1)) begin
                op1_v = ex0_result.result; s1_rdy = 1'b1;
            end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == enq_instr_1.rs1)) begin
                op1_v = mem1_result.result; s1_rdy = 1'b1;
            end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == enq_instr_1.rs1)) begin
                op1_v = mem0_result.result; s1_rdy = 1'b1;
            end else begin
                op1_v = rf_op1_1; s1_rdy = 1'b1;
            end

            // Resolve operand 2 (check enq_instr_0 dependency first)
            if (enq_instr_1.rs2 == 5'd0 || !enq_instr_1.use_rs2) begin
                op2_v = rf_op2_1; s2_rdy = 1'b1;
            end else if (enq_valid_0 && enq_instr_0.reg_write && (enq_instr_0.rd != 5'd0) && (enq_instr_0.rd == enq_instr_1.rs2)) begin
                op2_v = 32'd0; s2_rdy = 1'b0; // Depends on enq_instr_0!
            end else if (check_inflight_producer(enq_instr_1.rs2)) begin
                op2_v = 32'd0; s2_rdy = 1'b0;
            end else if (ex1_result.valid && ex1_result.reg_write && (ex1_result.rd == enq_instr_1.rs2)) begin
                op2_v = ex1_result.result; s2_rdy = 1'b1;
            end else if (ex0_result.valid && ex0_result.reg_write && (ex0_result.rd == enq_instr_1.rs2)) begin
                op2_v = ex0_result.result; s2_rdy = 1'b1;
            end else if (mem1_result.valid && mem1_result.reg_write && (mem1_result.rd == enq_instr_1.rs2)) begin
                op2_v = mem1_result.result; s2_rdy = 1'b1;
            end else if (mem0_result.valid && mem0_result.reg_write && (mem0_result.rd == enq_instr_1.rs2)) begin
                op2_v = mem0_result.result; s2_rdy = 1'b1;
            end else begin
                op2_v = rf_op2_1; s2_rdy = 1'b1;
            end

            queue_nxt[tail_nxt].valid    = 1'b1;
            queue_nxt[tail_nxt].instr    = enq_instr_1;
            queue_nxt[tail_nxt].op1      = op1_v;
            queue_nxt[tail_nxt].op2      = op2_v;
            queue_nxt[tail_nxt].src1_rdy = s1_rdy;
            queue_nxt[tail_nxt].src2_rdy = s2_rdy;

            tail_nxt  = PTR_W'((int'(tail_nxt) + 1) % IQ_DEPTH);
            count_nxt = count_nxt + 1;
        end

    end : comb_logic

    // =========================================================================
    // Synchronous state update
    // =========================================================================
    always_ff @(posedge clk) begin : seq_logic
        if (!rst_n || flush) begin
            for (int i = 0; i < IQ_DEPTH; i++) begin
                queue[i] <= '0;
            end
            head  <= '0;
            tail  <= '0;
            count <= '0;
        end else begin
            for (int i = 0; i < IQ_DEPTH; i++) begin
                queue[i] <= queue_nxt[i];
            end
            head  <= head_nxt;
            tail  <= tail_nxt;
            count <= count_nxt;
        end
    end : seq_logic

endmodule : issue_queue
