// =============================================================================
// File        : regfile.sv
// Project     : Superscalar RV32I Core
// Description : 32x32-bit multi-ported register file for dual-issue pipeline.
//               Provides 4 asynchronous read ports and 2 synchronous write ports
//               with write-before-read forwarding and x0 hardwired to zero.
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module regfile #(
    parameter int DEPTH = 32  // Number of architectural registers (RV32I = 32)
) (
    // -------------------------------------------------------------------------
    // Clock and Reset
    // -------------------------------------------------------------------------
    input  logic        clk,
    input  logic        rst_n,   // Synchronous active-low reset

    // -------------------------------------------------------------------------
    // Read Port 0 (Issue Slot 0 – rs1 and rs2)
    // -------------------------------------------------------------------------
    input  logic [4:0]  rs1_addr_0,   // Read address for slot-0 source 1
    input  logic [4:0]  rs2_addr_0,   // Read address for slot-0 source 2
    output logic [31:0] rs1_data_0,   // Read data for slot-0 source 1
    output logic [31:0] rs2_data_0,   // Read data for slot-0 source 2

    // -------------------------------------------------------------------------
    // Read Port 1 (Issue Slot 1 – rs1 and rs2)
    // -------------------------------------------------------------------------
    input  logic [4:0]  rs1_addr_1,   // Read address for slot-1 source 1
    input  logic [4:0]  rs2_addr_1,   // Read address for slot-1 source 2
    output logic [31:0] rs1_data_1,   // Read data for slot-1 source 1
    output logic [31:0] rs2_data_1,   // Read data for slot-1 source 2

    // -------------------------------------------------------------------------
    // Write Port 0 (highest priority – typically ALU result of slot 0)
    // -------------------------------------------------------------------------
    input  logic        we_0,         // Write enable for port 0
    input  logic [4:0]  rd_addr_0,    // Destination register address for port 0
    input  logic [31:0] rd_data_0,    // Data to write on port 0

    // -------------------------------------------------------------------------
    // Write Port 1 (lower priority – typically ALU result of slot 1)
    // -------------------------------------------------------------------------
    input  logic        we_1,         // Write enable for port 1
    input  logic [4:0]  rd_addr_1,    // Destination register address for port 1
    input  logic [31:0] rd_data_1     // Data to write on port 1
);

    // -------------------------------------------------------------------------
    // Internal register array
    // -------------------------------------------------------------------------
    // Register index 0 (x0) is never written; all other registers are general
    // purpose.  The array is unpacked so each element maps to a distinct FF bank
    // in synthesis, enabling the multi-ported implementation.
    // -------------------------------------------------------------------------
    logic [31:0] rf [0:DEPTH-1];

    // -------------------------------------------------------------------------
    // Synchronous Write Logic
    // Priority Scheme:
    //   - Write Port 0 takes precedence over Write Port 1.
    //   - If both ports target the SAME register in the same cycle, Port 0's
    //     data is written and Port 1's write is silently suppressed.
    //   - This models the typical dual-issue scenario where the in-order slot 0
    //     result is architecturally "later" (or simply given priority by design)
    //     when a structural WAW hazard occurs.
    //   - Writes to x0 (address 0) are always ignored to preserve the hardwired
    //     zero invariant.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Reset all registers to 0 on active-low synchronous reset
            for (int i = 0; i < DEPTH; i++) begin
                rf[i] <= 32'h0;
            end
        end else begin
            // ------------------------------------------------------------------
            // Write Port 1 is processed FIRST so that Port 0, processed second,
            // will overwrite Port 1's result if both target the same register.
            // This achieves Port 0 priority with a single always_ff block.
            // ------------------------------------------------------------------

            // Write Port 1 (lower priority)
            if (we_1 && (rd_addr_1 != 5'h0)) begin
                // Only write if Port 0 is NOT also writing to the same register.
                // If they collide, Port 0 wins; suppress Port 1 write here to
                // avoid a non-deterministic last-writer-wins race in simulation.
                if (!(we_0 && (rd_addr_0 == rd_addr_1))) begin
                    rf[rd_addr_1] <= rd_data_1;
                end
            end

            // Write Port 0 (higher priority – always wins any WAW conflict)
            if (we_0 && (rd_addr_0 != 5'h0)) begin
                rf[rd_addr_0] <= rd_data_0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Asynchronous Read Logic with Write-Before-Read (WBR) Forwarding
    //
    // Standard FPGA/ASIC register files do not forward write data to read ports
    // within the same cycle without explicit bypassing logic.  We implement
    // explicit write-before-read forwarding here so that a read and write to the
    // same address in the same clock cycle returns the NEW (written) value rather
    // than the stale registered value.
    //
    // Forwarding priority (when multiple write ports target the same register as
    // a read port):
    //   1. Write Port 0 data (highest)
    //   2. Write Port 1 data
    //   3. Registered array value (no write this cycle)
    //
    // x0 always reads as 32'h0 regardless of any write attempts.
    // -------------------------------------------------------------------------

    // ---- Read Port 0, rs1 ----
    always_comb begin
        if (rs1_addr_0 == 5'h0) begin
            // x0 is hardwired to zero
            rs1_data_0 = 32'h0;
        end else if (we_0 && (rd_addr_0 == rs1_addr_0)) begin
            // Write Port 0 forwarding (highest priority)
            rs1_data_0 = rd_data_0;
        end else if (we_1 && (rd_addr_1 == rs1_addr_0)) begin
            // Write Port 1 forwarding (lower priority)
            rs1_data_0 = rd_data_1;
        end else begin
            // Normal registered read
            rs1_data_0 = rf[rs1_addr_0];
        end
    end

    // ---- Read Port 0, rs2 ----
    always_comb begin
        if (rs2_addr_0 == 5'h0) begin
            rs2_data_0 = 32'h0;
        end else if (we_0 && (rd_addr_0 == rs2_addr_0)) begin
            rs2_data_0 = rd_data_0;
        end else if (we_1 && (rd_addr_1 == rs2_addr_0)) begin
            rs2_data_0 = rd_data_1;
        end else begin
            rs2_data_0 = rf[rs2_addr_0];
        end
    end

    // ---- Read Port 1, rs1 ----
    always_comb begin
        if (rs1_addr_1 == 5'h0) begin
            rs1_data_1 = 32'h0;
        end else if (we_0 && (rd_addr_0 == rs1_addr_1)) begin
            rs1_data_1 = rd_data_0;
        end else if (we_1 && (rd_addr_1 == rs1_addr_1)) begin
            rs1_data_1 = rd_data_1;
        end else begin
            rs1_data_1 = rf[rs1_addr_1];
        end
    end

    // ---- Read Port 1, rs2 ----
    always_comb begin
        if (rs2_addr_1 == 5'h0) begin
            rs2_data_1 = 32'h0;
        end else if (we_0 && (rd_addr_0 == rs2_addr_1)) begin
            rs2_data_1 = rd_data_0;
        end else if (we_1 && (rd_addr_1 == rs2_addr_1)) begin
            rs2_data_1 = rd_data_1;
        end else begin
            rs2_data_1 = rf[rs2_addr_1];
        end
    end

    // -------------------------------------------------------------------------
    // Assertions (synthesizable-safe: only enabled in simulation via SVA)
    // -------------------------------------------------------------------------
    // synthesis translate_off
    always_ff @(posedge clk) begin
        // Verify x0 is never accidentally written
        if (rst_n) begin
            assert (rf[0] == 32'h0)
                else $error("[regfile] x0 (rf[0]) was non-zero! Hardwired zero violated.");
        end
    end
    // synthesis translate_on

endmodule : regfile
