// =============================================================================
// decode_stage.sv
// Dual-issue Superscalar RV32I – Instruction Decode Stage
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module decode_stage (
    input  logic        clk,
    input  logic        rst_n,

    // ── Hazard Controls ─────────────────────────────────────────────────────
    input  logic        stall,       // Hold decode pipeline register
    input  logic        flush,       // Invalidate decode pipeline register

    // ── Fetch → Decode Inputs ───────────────────────────────────────────────
    input  logic [31:0] pc_in_0,
    input  logic [31:0] pc_in_1,
    input  logic [31:0] instr_in_0,
    input  logic [31:0] instr_in_1,
    input  logic        valid_in_0,
    input  logic        valid_in_1,

    // ── Decode → Dispatch Outputs ───────────────────────────────────────────
    output decoded_instr_t dec_out_0,  // Decoded instruction 0 (registered)
    output decoded_instr_t dec_out_1,  // Decoded instruction 1 (registered)

    // ── Intra-pair RAW Dependency Flag ──────────────────────────────────────
    output logic        intra_dep    // 1 → inst1 depends on inst0's result
);

    decoded_instr_t dec_comb_0;
    decoded_instr_t dec_comb_1;
    logic           intra_dep_comb;

    // -------------------------------------------------------------------------
    // Slot 0 Combinational Decode
    // -------------------------------------------------------------------------
    always_comb begin : decode_slot0
        dec_comb_0 = '0;

        dec_comb_0.pc        = pc_in_0;
        dec_comb_0.instr     = instr_in_0;
        dec_comb_0.valid     = valid_in_0;

        dec_comb_0.opcode    = instr_in_0[6:0];
        dec_comb_0.rd        = instr_in_0[11:7];
        dec_comb_0.funct3    = instr_in_0[14:12];
        dec_comb_0.rs1       = instr_in_0[19:15];
        dec_comb_0.rs2       = instr_in_0[24:20];
        dec_comb_0.funct7    = instr_in_0[31:25];

        dec_comb_0.imm_i = {{20{instr_in_0[31]}}, instr_in_0[31:20]};
        dec_comb_0.imm_s = {{20{instr_in_0[31]}}, instr_in_0[31:25], instr_in_0[11:7]};
        dec_comb_0.imm_b = {{19{instr_in_0[31]}}, instr_in_0[31], instr_in_0[7],
                             instr_in_0[30:25], instr_in_0[11:8], 1'b0};
        dec_comb_0.imm_u = {instr_in_0[31:12], 12'd0};
        dec_comb_0.imm_j = {{11{instr_in_0[31]}}, instr_in_0[31], instr_in_0[19:12],
                             instr_in_0[20], instr_in_0[30:21], 1'b0};

        unique case (instr_in_0[6:0])
            OPCODE_OP: begin
                dec_comb_0.cat       = CAT_ALU;
                dec_comb_0.use_rs1   = 1'b1;
                dec_comb_0.use_rs2   = 1'b1;
                dec_comb_0.use_imm   = 1'b0;
                dec_comb_0.use_pc    = 1'b0;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.imm       = 32'd0;
                unique case ({instr_in_0[31:25], instr_in_0[14:12]})
                    10'b0000000_000: dec_comb_0.alu_op = ALU_ADD;
                    10'b0100000_000: dec_comb_0.alu_op = ALU_SUB;
                    10'b0000000_001: dec_comb_0.alu_op = ALU_SLL;
                    10'b0000000_010: dec_comb_0.alu_op = ALU_SLT;
                    10'b0000000_011: dec_comb_0.alu_op = ALU_SLTU;
                    10'b0000000_100: dec_comb_0.alu_op = ALU_XOR;
                    10'b0000000_101: dec_comb_0.alu_op = ALU_SRL;
                    10'b0100000_101: dec_comb_0.alu_op = ALU_SRA;
                    10'b0000000_110: dec_comb_0.alu_op = ALU_OR;
                    10'b0000000_111: dec_comb_0.alu_op = ALU_AND;
                    default:         dec_comb_0.alu_op = ALU_ADD;
                endcase
            end

            OPCODE_OP_IMM: begin
                dec_comb_0.cat       = CAT_ALU;
                dec_comb_0.use_rs1   = 1'b1;
                dec_comb_0.use_rs2   = 1'b0;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b0;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_i;
                unique case (instr_in_0[14:12])
                    3'b000: dec_comb_0.alu_op = ALU_ADD;
                    3'b010: dec_comb_0.alu_op = ALU_SLT;
                    3'b011: dec_comb_0.alu_op = ALU_SLTU;
                    3'b100: dec_comb_0.alu_op = ALU_XOR;
                    3'b110: dec_comb_0.alu_op = ALU_OR;
                    3'b111: dec_comb_0.alu_op = ALU_AND;
                    3'b001: dec_comb_0.alu_op = ALU_SLL;
                    3'b101: dec_comb_0.alu_op = (instr_in_0[30]) ? ALU_SRA : ALU_SRL;
                    default: dec_comb_0.alu_op = ALU_ADD;
                endcase
            end

            OPCODE_LOAD: begin
                dec_comb_0.cat       = CAT_LOAD;
                dec_comb_0.use_rs1   = 1'b1;
                dec_comb_0.use_rs2   = 1'b0;
                dec_comb_0.alu_op    = ALU_ADD;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b0;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.mem_read  = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_i;
            end

            OPCODE_STORE: begin
                dec_comb_0.cat       = CAT_STORE;
                dec_comb_0.use_rs1   = 1'b1;
                dec_comb_0.use_rs2   = 1'b1;
                dec_comb_0.alu_op    = ALU_ADD;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b0;
                dec_comb_0.reg_write = 1'b0;
                dec_comb_0.mem_write = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_s;
            end

            OPCODE_BRANCH: begin
                dec_comb_0.cat       = CAT_BRANCH;
                dec_comb_0.use_rs1   = 1'b1;
                dec_comb_0.use_rs2   = 1'b1;
                dec_comb_0.use_imm   = 1'b0;
                dec_comb_0.use_pc    = 1'b1;
                dec_comb_0.reg_write = 1'b0;
                dec_comb_0.imm       = dec_comb_0.imm_b;
                unique case (instr_in_0[14:12])
                    3'b000: dec_comb_0.alu_op = ALU_SEQ;
                    3'b001: dec_comb_0.alu_op = ALU_SNE;
                    3'b100: dec_comb_0.alu_op = ALU_SLT;
                    3'b101: dec_comb_0.alu_op = ALU_SGE;
                    3'b110: dec_comb_0.alu_op = ALU_SLTU;
                    3'b111: dec_comb_0.alu_op = ALU_SGEU;
                    default: dec_comb_0.alu_op = ALU_ADD;
                endcase
            end

            OPCODE_LUI: begin
                dec_comb_0.cat       = CAT_ALU;
                dec_comb_0.use_rs1   = 1'b0;
                dec_comb_0.use_rs2   = 1'b0;
                dec_comb_0.alu_op    = ALU_COPY_B;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b0;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_u;
            end

            OPCODE_AUIPC: begin
                dec_comb_0.cat       = CAT_ALU;
                dec_comb_0.use_rs1   = 1'b0;
                dec_comb_0.use_rs2   = 1'b0;
                dec_comb_0.alu_op    = ALU_ADD;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b1;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_u;
            end

            OPCODE_JAL: begin
                dec_comb_0.cat       = CAT_JUMP;
                dec_comb_0.use_rs1   = 1'b0;
                dec_comb_0.use_rs2   = 1'b0;
                dec_comb_0.is_jal    = 1'b1;
                dec_comb_0.alu_op    = ALU_ADD;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b1;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_j;
            end

            OPCODE_JALR: begin
                dec_comb_0.cat       = CAT_JUMP;
                dec_comb_0.use_rs1   = 1'b1;
                dec_comb_0.use_rs2   = 1'b0;
                dec_comb_0.is_jalr   = 1'b1;
                dec_comb_0.alu_op    = ALU_ADD;
                dec_comb_0.use_imm   = 1'b1;
                dec_comb_0.use_pc    = 1'b0;
                dec_comb_0.reg_write = 1'b1;
                dec_comb_0.imm       = dec_comb_0.imm_i;
            end

            default: begin
                dec_comb_0.cat       = CAT_NOP;
                dec_comb_0.alu_op    = ALU_ADD;
            end
        endcase

        if (!valid_in_0) begin
            dec_comb_0.cat       = CAT_NOP;
            dec_comb_0.reg_write = 1'b0;
            dec_comb_0.mem_read  = 1'b0;
            dec_comb_0.mem_write = 1'b0;
            dec_comb_0.valid     = 1'b0;
        end
    end : decode_slot0

    // -------------------------------------------------------------------------
    // Slot 1 Combinational Decode
    // -------------------------------------------------------------------------
    always_comb begin : decode_slot1
        dec_comb_1 = '0;

        dec_comb_1.pc        = pc_in_1;
        dec_comb_1.instr     = instr_in_1;
        dec_comb_1.valid     = valid_in_1;

        dec_comb_1.opcode    = instr_in_1[6:0];
        dec_comb_1.rd        = instr_in_1[11:7];
        dec_comb_1.funct3    = instr_in_1[14:12];
        dec_comb_1.rs1       = instr_in_1[19:15];
        dec_comb_1.rs2       = instr_in_1[24:20];
        dec_comb_1.funct7    = instr_in_1[31:25];

        dec_comb_1.imm_i = {{20{instr_in_1[31]}}, instr_in_1[31:20]};
        dec_comb_1.imm_s = {{20{instr_in_1[31]}}, instr_in_1[31:25], instr_in_1[11:7]};
        dec_comb_1.imm_b = {{19{instr_in_1[31]}}, instr_in_1[31], instr_in_1[7],
                             instr_in_1[30:25], instr_in_1[11:8], 1'b0};
        dec_comb_1.imm_u = {instr_in_1[31:12], 12'd0};
        dec_comb_1.imm_j = {{11{instr_in_1[31]}}, instr_in_1[31], instr_in_1[19:12],
                             instr_in_1[20], instr_in_1[30:21], 1'b0};

        unique case (instr_in_1[6:0])
            OPCODE_OP: begin
                dec_comb_1.cat       = CAT_ALU;
                dec_comb_1.use_rs1   = 1'b1;
                dec_comb_1.use_rs2   = 1'b1;
                dec_comb_1.use_imm   = 1'b0;
                dec_comb_1.use_pc    = 1'b0;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.imm       = 32'd0;
                unique case ({instr_in_1[31:25], instr_in_1[14:12]})
                    10'b0000000_000: dec_comb_1.alu_op = ALU_ADD;
                    10'b0100000_000: dec_comb_1.alu_op = ALU_SUB;
                    10'b0000000_001: dec_comb_1.alu_op = ALU_SLL;
                    10'b0000000_010: dec_comb_1.alu_op = ALU_SLT;
                    10'b0000000_011: dec_comb_1.alu_op = ALU_SLTU;
                    10'b0000000_100: dec_comb_1.alu_op = ALU_XOR;
                    10'b0000000_101: dec_comb_1.alu_op = ALU_SRL;
                    10'b0100000_101: dec_comb_1.alu_op = ALU_SRA;
                    10'b0000000_110: dec_comb_1.alu_op = ALU_OR;
                    10'b0000000_111: dec_comb_1.alu_op = ALU_AND;
                    default:         dec_comb_1.alu_op = ALU_ADD;
                endcase
            end

            OPCODE_OP_IMM: begin
                dec_comb_1.cat       = CAT_ALU;
                dec_comb_1.use_rs1   = 1'b1;
                dec_comb_1.use_rs2   = 1'b0;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b0;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_i;
                unique case (instr_in_1[14:12])
                    3'b000: dec_comb_1.alu_op = ALU_ADD;
                    3'b010: dec_comb_1.alu_op = ALU_SLT;
                    3'b011: dec_comb_1.alu_op = ALU_SLTU;
                    3'b100: dec_comb_1.alu_op = ALU_XOR;
                    3'b110: dec_comb_1.alu_op = ALU_OR;
                    3'b111: dec_comb_1.alu_op = ALU_AND;
                    3'b001: dec_comb_1.alu_op = ALU_SLL;
                    3'b101: dec_comb_1.alu_op = (instr_in_1[30]) ? ALU_SRA : ALU_SRL;
                    default: dec_comb_1.alu_op = ALU_ADD;
                endcase
            end

            OPCODE_LOAD: begin
                dec_comb_1.cat       = CAT_LOAD;
                dec_comb_1.use_rs1   = 1'b1;
                dec_comb_1.use_rs2   = 1'b0;
                dec_comb_1.alu_op    = ALU_ADD;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b0;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.mem_read  = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_i;
            end

            OPCODE_STORE: begin
                dec_comb_1.cat       = CAT_STORE;
                dec_comb_1.use_rs1   = 1'b1;
                dec_comb_1.use_rs2   = 1'b1;
                dec_comb_1.alu_op    = ALU_ADD;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b0;
                dec_comb_1.reg_write = 1'b0;
                dec_comb_1.mem_write = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_s;
            end

            OPCODE_BRANCH: begin
                dec_comb_1.cat       = CAT_BRANCH;
                dec_comb_1.use_rs1   = 1'b1;
                dec_comb_1.use_rs2   = 1'b1;
                dec_comb_1.use_imm   = 1'b0;
                dec_comb_1.use_pc    = 1'b1;
                dec_comb_1.reg_write = 1'b0;
                dec_comb_1.imm       = dec_comb_1.imm_b;
                unique case (instr_in_1[14:12])
                    3'b000: dec_comb_1.alu_op = ALU_SEQ;
                    3'b001: dec_comb_1.alu_op = ALU_SNE;
                    3'b100: dec_comb_1.alu_op = ALU_SLT;
                    3'b101: dec_comb_1.alu_op = ALU_SGE;
                    3'b110: dec_comb_1.alu_op = ALU_SLTU;
                    3'b111: dec_comb_1.alu_op = ALU_SGEU;
                    default: dec_comb_1.alu_op = ALU_ADD;
                endcase
            end

            OPCODE_LUI: begin
                dec_comb_1.cat       = CAT_ALU;
                dec_comb_1.use_rs1   = 1'b0;
                dec_comb_1.use_rs2   = 1'b0;
                dec_comb_1.alu_op    = ALU_COPY_B;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b0;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_u;
            end

            OPCODE_AUIPC: begin
                dec_comb_1.cat       = CAT_ALU;
                dec_comb_1.use_rs1   = 1'b0;
                dec_comb_1.use_rs2   = 1'b0;
                dec_comb_1.alu_op    = ALU_ADD;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b1;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_u;
            end

            OPCODE_JAL: begin
                dec_comb_1.cat       = CAT_JUMP;
                dec_comb_1.use_rs1   = 1'b0;
                dec_comb_1.use_rs2   = 1'b0;
                dec_comb_1.is_jal    = 1'b1;
                dec_comb_1.alu_op    = ALU_ADD;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b1;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_j;
            end

            OPCODE_JALR: begin
                dec_comb_1.cat       = CAT_JUMP;
                dec_comb_1.use_rs1   = 1'b1;
                dec_comb_1.use_rs2   = 1'b0;
                dec_comb_1.is_jalr   = 1'b1;
                dec_comb_1.alu_op    = ALU_ADD;
                dec_comb_1.use_imm   = 1'b1;
                dec_comb_1.use_pc    = 1'b0;
                dec_comb_1.reg_write = 1'b1;
                dec_comb_1.imm       = dec_comb_1.imm_i;
            end

            default: begin
                dec_comb_1.cat       = CAT_NOP;
                dec_comb_1.alu_op    = ALU_ADD;
            end
        endcase

        if (!valid_in_1) begin
            dec_comb_1.cat       = CAT_NOP;
            dec_comb_1.reg_write = 1'b0;
            dec_comb_1.mem_read  = 1'b0;
            dec_comb_1.mem_write = 1'b0;
            dec_comb_1.valid     = 1'b0;
        end
    end : decode_slot1

    // -------------------------------------------------------------------------
    // Intra-pair RAW Dependency Detection (Status)
    // -------------------------------------------------------------------------
    always_comb begin : intra_dep_logic
        intra_dep_comb = valid_in_0 && valid_in_1     &&
                         dec_comb_0.reg_write          &&
                         (dec_comb_0.rd != 5'd0)       &&
                         ( (dec_comb_0.rd == dec_comb_1.rs1) ||
                           (dec_comb_0.rd == dec_comb_1.rs2) );
    end : intra_dep_logic

    // -------------------------------------------------------------------------
    // Decode Pipeline Registers
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            dec_out_0 <= '0;
            dec_out_1 <= '0;
            intra_dep <= 1'b0;
        end else if (!stall) begin
            dec_out_0 <= dec_comb_0;
            dec_out_1 <= dec_comb_1;
            intra_dep <= intra_dep_comb;
        end
    end

endmodule : decode_stage
