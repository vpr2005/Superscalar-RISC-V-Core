// =============================================================================
// riscv_pkg.sv  (Authoritative Unified Package)
// Project     : Dual-Issue Superscalar RV32I Core
// Description : Single source of truth for all shared types, enumerations,
//               constants, and struct definitions used across the entire RTL
//               hierarchy. Every module begins with:  import riscv_pkg::*;
// =============================================================================

`ifndef RISCV_PKG_SV
`define RISCV_PKG_SV

`timescale 1ns/1ps

package riscv_pkg;

    // =========================================================================
    // Global Architecture Constants
    // =========================================================================
    localparam int XLEN    = 32;
    localparam int REG_CNT = 32;
    localparam int REG_W   = 5;

    // =========================================================================
    // RV32I Base Opcode (inst[6:0])
    // =========================================================================
    localparam logic [6:0] OPCODE_LOAD   = 7'b000_0011;
    localparam logic [6:0] OPCODE_STORE  = 7'b010_0011;
    localparam logic [6:0] OPCODE_OP     = 7'b011_0011;  // R-type
    localparam logic [6:0] OPCODE_OP_IMM = 7'b001_0011;  // I-type ALU
    localparam logic [6:0] OPCODE_LUI    = 7'b011_0111;
    localparam logic [6:0] OPCODE_AUIPC  = 7'b001_0111;
    localparam logic [6:0] OPCODE_JAL    = 7'b110_1111;
    localparam logic [6:0] OPCODE_JALR   = 7'b110_0111;
    localparam logic [6:0] OPCODE_BRANCH = 7'b110_0011;
    localparam logic [6:0] OPCODE_SYSTEM = 7'b111_0011;
    localparam logic [6:0] OPCODE_FENCE  = 7'b000_1111;

    // =========================================================================
    // funct3 for Branch Instructions
    // =========================================================================
    localparam logic [2:0] F3_BEQ  = 3'b000;
    localparam logic [2:0] F3_BNE  = 3'b001;
    localparam logic [2:0] F3_BLT  = 3'b100;
    localparam logic [2:0] F3_BGE  = 3'b101;
    localparam logic [2:0] F3_BLTU = 3'b110;
    localparam logic [2:0] F3_BGEU = 3'b111;

    // funct3 for Load / Store
    localparam logic [2:0] F3_LB  = 3'b000;
    localparam logic [2:0] F3_LH  = 3'b001;
    localparam logic [2:0] F3_LW  = 3'b010;
    localparam logic [2:0] F3_LBU = 3'b100;
    localparam logic [2:0] F3_LHU = 3'b101;
    localparam logic [2:0] F3_SB  = 3'b000;
    localparam logic [2:0] F3_SH  = 3'b001;
    localparam logic [2:0] F3_SW  = 3'b010;

    // =========================================================================
    // ALU Operation Encoding  (alu_op_e – 4-bit typedef enum)
    // Covers all RV32I ALU ops + branch comparators + LUI pass-through
    // =========================================================================
    typedef enum logic [3:0] {
        ALU_ADD    = 4'b0000,   // Add  / ADDI / AUIPC / JAL / JALR target
        ALU_SUB    = 4'b0001,   // Subtract
        ALU_AND    = 4'b0010,   // Bitwise AND
        ALU_OR     = 4'b0011,   // Bitwise OR
        ALU_XOR    = 4'b0100,   // Bitwise XOR
        ALU_SLL    = 4'b0101,   // Logical shift left
        ALU_SRL    = 4'b0110,   // Logical shift right
        ALU_SRA    = 4'b0111,   // Arithmetic shift right
        ALU_SLT    = 4'b1000,   // Set-less-than   (signed)   / BLT comparator
        ALU_SLTU   = 4'b1001,   // Set-less-than   (unsigned) / BLTU comparator
        ALU_SEQ    = 4'b1010,   // Set-equal       / BEQ comparator
        ALU_SNE    = 4'b1011,   // Set-not-equal   / BNE comparator
        ALU_SGE    = 4'b1100,   // Set-≥           (signed)   / BGE comparator
        ALU_SGEU   = 4'b1101,   // Set-≥           (unsigned) / BGEU comparator
        ALU_COPY_B = 4'b1110,   // Pass operand B unchanged  (LUI)
        ALU_NOP    = 4'b1111    // No-operation
    } alu_op_e;

    // =========================================================================
    // Instruction Category
    // =========================================================================
    typedef enum logic [2:0] {
        CAT_NOP    = 3'd0,
        CAT_ALU    = 3'd1,
        CAT_LOAD   = 3'd2,
        CAT_STORE  = 3'd3,
        CAT_BRANCH = 3'd4,
        CAT_JUMP   = 3'd5,   // JAL and JALR
        CAT_SYSTEM = 3'd6,
        CAT_FENCE  = 3'd7
    } instr_cat_e;

    // =========================================================================
    // Memory Access Width
    // =========================================================================
    typedef enum logic [1:0] {
        MEM_BYTE = 2'b00,
        MEM_HALF = 2'b01,
        MEM_WORD = 2'b10,
        MEM_RSVD = 2'b11
    } mem_width_e;

    // =========================================================================
    // Decoded Instruction Descriptor
    // Populated by decode_stage and carried through the pipeline.
    // =========================================================================
    typedef struct packed {
        // ── Instruction validity ──────────────────────────────────────────────
        logic           valid;          // 1 = this slot holds a real instruction

        // ── PC of this instruction ────────────────────────────────────────────
        logic [31:0]    pc;

        // ── Raw instruction word (for debugging) ──────────────────────────────
        logic [31:0]    instr;          // Raw 32-bit instruction word

        // ── Register specifiers ───────────────────────────────────────────────
        logic [REG_W-1:0]  rd;          // Destination register
        logic [REG_W-1:0]  rs1;         // Source register 1
        logic [REG_W-1:0]  rs2;         // Source register 2

        // ── Source register usage flags ───────────────────────────────────────
        logic           use_rs1;        // Instruction reads rs1
        logic           use_rs2;        // Instruction reads rs2
        logic           reg_write;      // Instruction writes rd

        // ── Immediate value (sign-extended to 32 bits, active form) ──────────
        logic [31:0]    imm;            // Selected immediate
        logic [31:0]    imm_i;          // I-type immediate
        logic [31:0]    imm_s;          // S-type immediate
        logic [31:0]    imm_b;          // B-type immediate
        logic [31:0]    imm_u;          // U-type immediate
        logic [31:0]    imm_j;          // J-type immediate
        logic           use_imm;        // Use imm as ALU operand B (not rs2)
        logic           use_pc;         // Use PC as ALU operand A (AUIPC/JAL)

        // ── Opcode raw fields (kept for downstream disambiguation) ────────────
        logic [6:0]     opcode;
        logic [2:0]     funct3;
        logic [6:0]     funct7;

        // ── Execution unit controls ───────────────────────────────────────────
        alu_op_e        alu_op;         // ALU function select
        instr_cat_e     cat;            // Instruction category

        // ── Memory access controls ────────────────────────────────────────────
        logic           mem_read;       // Load instruction
        logic           mem_write;      // Store instruction
        logic           mem_sign_ext;   // Sign-extend on load (LB/LH)
        mem_width_e     mem_width;      // Byte / Half / Word

        // ── Jump flags ────────────────────────────────────────────────────────
        logic           is_jal;         // JAL instruction
        logic           is_jalr;        // JALR instruction

        // ── System / environment flags ────────────────────────────────────────
        logic           is_ecall;
        logic           is_ebreak;
        logic           is_fence;

        // ── Reorder Buffer Tag ────────────────────────────────────────────────
        logic [3:0]     rob_tag;
    } decoded_instr_t;

    // =========================================================================
    // Execution Result Descriptor  (forwarding bus + commit bus)
    // Produced by EX/MEM stage; broadcast on forwarding buses and used by ROB.
    // =========================================================================
    typedef struct packed {
        logic           valid;          // 1 = this result is live
        logic [REG_W-1:0]  rd;          // Destination architectural register
        logic [31:0]    result;         // ALU result / load data / return address
        logic           reg_write;      // This result writes a register
        logic           mem_read;       // Result came from (or is still a) load
                                        //   – used by hazard unit for load-use
        logic           branch_taken;   // Branch resolved as taken
        logic [31:0]    branch_target;  // Computed branch / jump target PC
        logic [3:0]     rob_tag;        // Reorder Buffer tag for completion matching
    } ex_result_t;

endpackage : riscv_pkg

`endif // RISCV_PKG_SV
