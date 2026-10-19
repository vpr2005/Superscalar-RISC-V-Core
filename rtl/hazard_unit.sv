// =============================================================================
// File        : hazard_unit.sv
// Project     : Dual-Issue Superscalar RV32I Core
// Description : Combinational hazard detection and pipeline control unit.
//
//   Hazard classes handled:
//
//   1. LOAD-USE HAZARD
//      When an EX-stage instruction is a load (mem_read asserted) and its
//      destination register (rd) matches rs1 or rs2 of EITHER decode-stage
//      instruction, the result is not yet available.  The pipeline must stall
//      fetch and decode for ONE cycle so that the load result can be forwarded
//      on the next cycle.
//
//      Affected signals: stall_fetch, stall_decode, stall_issue
//      The issue stage is also stalled to prevent the dependent instructions
//      from advancing until the data is ready.
//
//   2. BRANCH MISPREDICTION
//      This core uses a predict-not-taken strategy.  When an execution unit
//      confirms a branch IS taken, the instructions fetched speculatively
//      after the branch are wrong.  Flush fetch and decode pipeline registers
//      and redirect the fetch PC to the branch target.
//
//      Two execution pipes may each signal a branch independently.
//      Priority: pipeline 0 > pipeline 1 (both cannot be taken simultaneously
//      in a correct program, but the arbiter picks the lower-index pipe).
//
//      Affected signals: flush_fetch, flush_decode, redirect_valid,
//                        redirect_target
//
//   Stall and flush interaction:
//     A stall takes priority over a flush for the decode and issue stages
//     when a load-use hazard and a branch taken occur simultaneously (rare
//     but legal).  The load-use stall holds the decode instruction in place;
//     the speculative instructions behind it are flushed from fetch.
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module hazard_unit (
    // ── Decoded instructions (Decode stage, current cycle) ───────────────────
    input  decoded_instr_t  dec_0,              // Decode pipeline 0
    input  decoded_instr_t  dec_1,              // Decode pipeline 1

    // ── EX stage metadata (for load-use detection) ───────────────────────────
    input  ex_result_t      ex0_result,         // EX pipeline 0 result/meta
    input  ex_result_t      ex1_result,         // EX pipeline 1 result/meta

    // ── Branch resolution signals (from execution units) ────────────────────
    input  logic            branch_taken_0,     // Branch resolved taken, pipe 0
    input  logic            branch_taken_1,     // Branch resolved taken, pipe 1
    input  logic [31:0]     branch_target_0,    // Target PC, pipe 0
    input  logic [31:0]     branch_target_1,    // Target PC, pipe 1

    // ── Stall controls (active-high, registered by each stage) ───────────────
    output logic            stall_fetch,        // Hold Fetch stage PC register
    output logic            stall_decode,       // Hold Decode stage pipeline reg
    output logic            stall_issue,        // Hold Issue stage pipeline reg

    // ── Flush controls (insert bubble into stage output registers) ───────────
    output logic            flush_fetch,        // Flush instructions in Fetch
    output logic            flush_decode,       // Flush instructions in Decode
    output logic            flush_issue,        // Flush instructions in Issue

    // ── PC redirect (to Fetch stage) ─────────────────────────────────────────
    output logic            redirect_valid,     // Fetch must load redirect_target
    output logic [31:0]     redirect_target     // Correct next-PC after branch
);

    // =========================================================================
    // Internal combinational flags
    // =========================================================================

    // --- Load-use hazard flags ------------------------------------------------
    // Check EX pipeline 0: is it a load whose rd collides with either decode rs?
    logic load_use_ex0;
    // Check EX pipeline 1: same check
    logic load_use_ex1;
    // Combined stall request from any load-use hazard
    logic load_use_stall;

    // =========================================================================
    // Load-Use Hazard Detection
    // =========================================================================
    // A load-use hazard exists when:
    //   - The EX-stage instruction is a LOAD  (ex_result.mem_read == 1)
    //   - The EX-stage instruction has a valid destination (rd != 0)
    //   - That destination matches rs1 or rs2 of EITHER decode instruction
    //
    // We check both EX pipelines independently.
    // =========================================================================

    always_comb begin : load_use_detect
        // Default: no hazard
        load_use_ex0 = 1'b0;
        load_use_ex1 = 1'b0;

        // EX Pipeline 0 load-use check
        if (ex0_result.valid       &&    // EX0 has a live instruction
            ex0_result.mem_read    &&    // It is a load
            ex0_result.rd != 5'd0) begin // Destination is not x0
            // Collision with decode instruction 0?
            if (dec_0.valid && ((dec_0.rs1 == ex0_result.rd) ||
                                (dec_0.rs2 == ex0_result.rd))) begin
                load_use_ex0 = 1'b1;
            end
            // Collision with decode instruction 1?
            if (dec_1.valid && ((dec_1.rs1 == ex0_result.rd) ||
                                (dec_1.rs2 == ex0_result.rd))) begin
                load_use_ex0 = 1'b1;
            end
        end

        // EX Pipeline 1 load-use check
        if (ex1_result.valid       &&
            ex1_result.mem_read    &&
            ex1_result.rd != 5'd0) begin
            if (dec_0.valid && ((dec_0.rs1 == ex1_result.rd) ||
                                (dec_0.rs2 == ex1_result.rd))) begin
                load_use_ex1 = 1'b1;
            end
            if (dec_1.valid && ((dec_1.rs1 == ex1_result.rd) ||
                                (dec_1.rs2 == ex1_result.rd))) begin
                load_use_ex1 = 1'b1;
            end
        end

        // Combined load-use stall request
        load_use_stall = load_use_ex0 | load_use_ex1;
    end : load_use_detect

    // =========================================================================
    // Branch Misprediction Handling
    // =========================================================================
    // When a branch is confirmed taken, the speculatively-fetched instructions
    // behind it must be discarded (flushed).
    // Pipeline 0 takes priority; if both pipes signal taken simultaneously
    // (should not happen in a correct superscalar window but handled safely),
    // pipe 0 wins.
    // =========================================================================

    always_comb begin : branch_redirect
        redirect_valid  = 1'b0;
        redirect_target = 32'd0;

        if (branch_taken_0) begin
            // Pipeline 0 branch taken – highest priority
            redirect_valid  = 1'b1;
            redirect_target = branch_target_0;
        end else if (branch_taken_1) begin
            // Pipeline 1 branch taken – secondary priority
            redirect_valid  = 1'b1;
            redirect_target = branch_target_1;
        end
    end : branch_redirect

    // =========================================================================
    // Stall / Flush Output Logic
    // =========================================================================
    //
    // Signal semantics:
    //   stall_X  – stage X must hold its current instruction(s) unchanged.
    //              The stage immediately upstream must also stall so no data
    //              is lost.
    //   flush_X  – stage X must replace its pipeline register(s) with NOPs
    //              (bubbles) on the next clock edge.
    //
    // Priority resolution:
    //   Load-use stall     : stall fetch + decode + issue; flush issue output
    //                        (insert bubble into EX so the load completes).
    //   Branch misprediction: flush fetch + decode (kill speculative instructions).
    //   Both simultaneously : stall dominates decode/issue; flush dominates fetch.
    // =========================================================================

    always_comb begin : output_ctrl
        // ── Stall signals ─────────────────────────────────────────────────────
        // Stall when a load-use hazard forces the dependent instructions to wait.
        stall_fetch  = load_use_stall;
        stall_decode = load_use_stall;
        stall_issue  = load_use_stall;

        // ── Flush signals ─────────────────────────────────────────────────────
        // flush_fetch: kill instructions that entered Fetch during a misprediction.
        flush_fetch  = redirect_valid;

        // flush_decode: kill decode-stage instructions on misprediction.
        //              On load-use stall, decode is held by stall_decode;
        //              issue enqueue is prevented by stall_issue, naturally inserting
        //              a bubble without erasing the instruction from decode.
        flush_decode = redirect_valid;

        // flush_issue: also flush the issue stage on a branch misprediction to
        //              prevent any already-issued (but not yet executed)
        //              speculative instructions from committing.
        flush_issue  = redirect_valid;
    end : output_ctrl

endmodule : hazard_unit
