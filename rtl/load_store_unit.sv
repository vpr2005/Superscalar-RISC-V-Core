// =============================================================================
// File        : load_store_unit.sv
// Project     : Superscalar RV32I Core
// Description : Load/Store Unit (LSU) for RV32I.
//               Performs address calculation, byte-enable generation, store-data
//               lane alignment, load-data sign/zero extension, misalignment
//               detection, and memory request handshaking.  All logic is purely
//               combinational; the surrounding pipeline registers are external.
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module load_store_unit (
    // -------------------------------------------------------------------------
    // Clock and Reset (retained for potential future registered extensions)
    // -------------------------------------------------------------------------
    input  logic        clk,
    input  logic        rst_n,    // Synchronous active-low reset

    // -------------------------------------------------------------------------
    // Address Generation Inputs
    // -------------------------------------------------------------------------
    input  logic [31:0] base_addr,  // rs1 value (base address register)
    input  logic [31:0] offset,     // Sign-extended immediate from instruction

    // -------------------------------------------------------------------------
    // Operation Qualifier Inputs
    // -------------------------------------------------------------------------
    input  logic [2:0]  funct3,     // Encodes access width and sign extension:
                                    //   3'b000 = LB  / SB
                                    //   3'b001 = LH  / SH
                                    //   3'b010 = LW  / SW
                                    //   3'b100 = LBU (zero-extend byte)
                                    //   3'b101 = LHU (zero-extend half)
    input  logic        is_load,    // High when instruction is a LOAD
    input  logic        is_store,   // High when instruction is a STORE

    // -------------------------------------------------------------------------
    // Store Data Input
    // -------------------------------------------------------------------------
    input  logic [31:0] store_data, // Data from rs2 to be written to memory

    // -------------------------------------------------------------------------
    // Memory Interface – Outputs (to data memory / D-cache)
    // -------------------------------------------------------------------------
    output logic [31:0] mem_addr,     // Byte address sent to memory
    output logic [3:0]  mem_byte_en,  // Active-high byte enables (one per byte lane)
    output logic [31:0] mem_wdata,    // Store data aligned to the correct byte lanes
    output logic        mem_req_valid,// High when a valid load or store is requested

    // -------------------------------------------------------------------------
    // Memory Interface – Input (from data memory / D-cache)
    // -------------------------------------------------------------------------
    input  logic [31:0] mem_rdata,    // Raw 32-bit word returned by memory

    // -------------------------------------------------------------------------
    // Load Result Output
    // -------------------------------------------------------------------------
    output logic [31:0] load_result,  // Sign- or zero-extended load data

    // -------------------------------------------------------------------------
    // Exception / Error Outputs
    // -------------------------------------------------------------------------
    output logic        misalign_err  // High on misaligned access (trap source)
);

    // -------------------------------------------------------------------------
    // Local Parameter – funct3 Encodings (RV32I spec Table 2.2 / 2.4)
    // -------------------------------------------------------------------------
    localparam logic [2:0] F3_BYTE      = 3'b000; // LB  / SB  – signed byte
    localparam logic [2:0] F3_HALF      = 3'b001; // LH  / SH  – signed halfword
    localparam logic [2:0] F3_WORD      = 3'b010; // LW  / SW  – word
    localparam logic [2:0] F3_BYTE_U    = 3'b100; // LBU        – unsigned byte
    localparam logic [2:0] F3_HALF_U    = 3'b101; // LHU        – unsigned halfword

    // -------------------------------------------------------------------------
    // Step 1 – Address Calculation (combinational adder)
    // mem_addr = base_addr + offset
    // The offset is already sign-extended by the decode stage before arriving
    // here.  A 32-bit adder produces the effective byte address with natural
    // wrap-around on overflow (matching RISC-V spec).
    // -------------------------------------------------------------------------
    always_comb begin
        mem_addr = base_addr + offset;
    end

    // -------------------------------------------------------------------------
    // Step 2 – Misalignment Detection
    // RV32I requires:
    //   LH/SH  – address must be 2-byte aligned (addr[0] == 0)
    //   LW/SW  – address must be 4-byte aligned (addr[1:0] == 2'b00)
    //   LB/SB  – byte accesses are always aligned
    // -------------------------------------------------------------------------
    always_comb begin
        case (funct3)
            F3_HALF,
            F3_HALF_U : misalign_err = (is_load | is_store) & mem_addr[0];
                                       // Half-word: bit 0 must be 0
            F3_WORD   : misalign_err = (is_load | is_store) & (|mem_addr[1:0]);
                                       // Word: bits [1:0] must both be 0
            default   : misalign_err = 1'b0; // Byte accesses never misalign
        endcase
    end

    // -------------------------------------------------------------------------
    // Step 3 – Byte Enable Generation
    // The data memory is assumed to be a 32-bit wide, byte-addressable memory
    // with 4 individual byte enables.  Byte lane mapping (little-endian):
    //
    //   mem_byte_en[3] = byte at addr+3  (most-significant byte of word)
    //   mem_byte_en[2] = byte at addr+2
    //   mem_byte_en[1] = byte at addr+1
    //   mem_byte_en[0] = byte at addr+0  (least-significant byte of word)
    //
    // addr[1:0] selects the starting lane within the aligned word:
    //
    //   SB: one bit set, shifted left by addr[1:0]
    //       e.g. addr[1:0]=2'b01 => mem_byte_en = 4'b0010
    //
    //   SH: two bits set, shifted left by addr[1:0] (aligned means 0 or 2)
    //       e.g. addr[1:0]=2'b10 => mem_byte_en = 4'b1100
    //
    //   SW: all four bits set (only valid when addr[1:0]==2'b00)
    //       => mem_byte_en = 4'b1111
    //
    // For loads, byte enables indicate which bytes to sample from mem_rdata.
    // -------------------------------------------------------------------------
    always_comb begin
        if (is_load | is_store) begin
            case (funct3)
                F3_BYTE,
                F3_BYTE_U : begin
                    // Shift a single byte-enable to the addressed lane
                    mem_byte_en = 4'b0001 << mem_addr[1:0];
                end

                F3_HALF,
                F3_HALF_U : begin
                    // Shift two consecutive byte-enables to the addressed lane.
                    // Half-word accesses start on even byte boundaries only
                    // (addr[0]==0), so addr[1] selects lower or upper half.
                    mem_byte_en = 4'b0011 << mem_addr[1:0];
                end

                F3_WORD : begin
                    // Word accesses occupy all four lanes
                    mem_byte_en = 4'b1111;
                end

                default : mem_byte_en = 4'b0000; // Undefined funct3
            endcase
        end else begin
            mem_byte_en = 4'b0000; // No memory operation active
        end
    end

    // -------------------------------------------------------------------------
    // Step 4 – Store Data Lane Alignment (mem_wdata)
    // The store data (from rs2) must be placed into the correct byte lane(s)
    // of the 32-bit write bus so that the memory subsystem writes the right
    // physical bytes.
    //
    //   SB: replicate the byte to all lanes OR shift it to addr[1:0] lane.
    //       We shift so that only the enabled lane carries valid data.
    //
    //   SH: shift the halfword so it aligns with the selected lane pair.
    //
    //   SW: no shifting needed (always word-aligned).
    // -------------------------------------------------------------------------
    always_comb begin
        case (funct3)
            F3_BYTE : begin
                // Place the least-significant byte of rs2 into the target lane.
                // Shifting by {addr[1:0], 3'b000} positions it correctly.
                mem_wdata = {24'h0, store_data[7:0]} << {mem_addr[1:0], 3'b000};
            end

            F3_HALF : begin
                // Place the least-significant halfword of rs2 into the target
                // lane pair.  addr[1] selects upper (1) or lower (0) pair.
                mem_wdata = {16'h0, store_data[15:0]} << {mem_addr[1], 4'b0000};
            end

            F3_WORD : begin
                // Full word; no lane shifting required.
                mem_wdata = store_data;
            end

            default : begin
                // Not a store, or undefined funct3 – drive bus to zero.
                mem_wdata = 32'h0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Step 5 – Load Result Extraction and Sign/Zero Extension
    // mem_rdata returns the full 32-bit aligned word from memory.  We must
    // extract the relevant byte/halfword from the correct lane and then either
    // sign-extend (LB, LH) or zero-extend (LBU, LHU) to 32 bits.  LW passes
    // the full word unchanged.
    //
    // Extraction uses addr[1:0] to select the starting byte position within
    // the 32-bit word (consistent with the byte-enable scheme above).
    // -------------------------------------------------------------------------

    // Internal wires for extracted (unextended) fields
    logic [7:0]  byte_lane;   // Selected 8-bit byte from mem_rdata
    logic [15:0] half_lane;   // Selected 16-bit halfword from mem_rdata

    always_comb begin
        // ---- Byte lane selection ----
        // addr[1:0] directly indexes which of the four bytes to pick.
        case (mem_addr[1:0])
            2'b00 : byte_lane = mem_rdata[ 7: 0];
            2'b01 : byte_lane = mem_rdata[15: 8];
            2'b10 : byte_lane = mem_rdata[23:16];
            2'b11 : byte_lane = mem_rdata[31:24];
            default: byte_lane = 8'h0;
        endcase

        // ---- Halfword lane selection ----
        // addr[1] selects whether the halfword starts at byte 0 or byte 2.
        // (addr[0] must be 0 for aligned half; misalign_err handles violation.)
        case (mem_addr[1])
            1'b0 : half_lane = mem_rdata[15: 0];
            1'b1 : half_lane = mem_rdata[31:16];
            default: half_lane = 16'h0;
        endcase

        // ---- Sign/Zero extension ----
        case (funct3)
            F3_BYTE   : load_result = {{24{byte_lane[7]}}, byte_lane};  // Sign-extend
            F3_HALF   : load_result = {{16{half_lane[15]}}, half_lane}; // Sign-extend
            F3_WORD   : load_result = mem_rdata;                         // Full word
            F3_BYTE_U : load_result = {24'h0, byte_lane};               // Zero-extend
            F3_HALF_U : load_result = {16'h0, half_lane};               // Zero-extend
            default   : load_result = 32'h0;                             // Undefined
        endcase
    end

    // -------------------------------------------------------------------------
    // Step 6 – Memory Request Valid
    // Asserted whenever a load or store is active AND there is no misalignment
    // error.  A misaligned access raises a trap and must NOT propagate a
    // request to the memory subsystem.
    // -------------------------------------------------------------------------
    always_comb begin
        mem_req_valid = (is_load | is_store) & ~misalign_err;
    end

endmodule : load_store_unit
