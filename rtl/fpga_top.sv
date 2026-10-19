// =============================================================================
// File        : fpga_top.sv
// Project     : Dual-Issue Superscalar RV32I Core
// Description : Synthesizable FPGA Top-Level SoC Wrapper for Artix-7 (CPG236 / Basys 3).
//               Integrates the core with on-chip Block RAMs and board I/O
//               (clock, reset button, slide switches, and LEDs), keeping total
//               pin count well under the 106-pin package limit.
// =============================================================================

`timescale 1ns/1ps

import riscv_pkg::*;

module fpga_top (
    input  logic        clk,            // 100 MHz oscillator input (pin W5 on Basys 3)
    input  logic        btnC,           // Center push button: Active-high reset (pin U18)
    input  logic [15:0] sw,             // 16 slide switches (pins V17..R2)
    output logic [15:0] led             // 16 user LEDs (pins U16..L1)
);

    // -------------------------------------------------------------------------
    // Reset generation (Active-low internal reset from Active-high button)
    // -------------------------------------------------------------------------
    logic rst_n_sync, rst_n_meta;
    always_ff @(posedge clk) begin
        rst_n_meta <= ~btnC;
        rst_n_sync <= rst_n_meta;
    end

    // -------------------------------------------------------------------------
    // Core memory buses
    // -------------------------------------------------------------------------
    logic [31:0] imem_addr;
    logic [63:0] imem_rdata;

    logic [31:0] dmem_addr;
    logic        dmem_rd_en;
    logic [31:0] dmem_rdata;
    logic        dmem_wr_en;
    logic [3:0]  dmem_byte_en;
    logic [31:0] dmem_wdata;

    // -------------------------------------------------------------------------
    // Core Instantiation
    // -------------------------------------------------------------------------
    superscalar_core u_core (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .imem_addr    (imem_addr),
        .imem_rdata   (imem_rdata),
        .dmem_addr    (dmem_addr),
        .dmem_rd_en   (dmem_rd_en),
        .dmem_rdata   (dmem_rdata),
        .dmem_wr_en   (dmem_wr_en),
        .dmem_byte_en (dmem_byte_en),
        .dmem_wdata   (dmem_wdata)
    );

    // -------------------------------------------------------------------------
    // On-Chip Instruction Memory (1024 x 32-bit words = 4KB, 64-bit dual read)
    // Inferred as Block RAM (BRAM) by Vivado
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [31:0] imem [0:1023];

    // Pre-load default verification workload:
    initial begin
        // ADDI x1, x0, 10
        imem[0] = 32'h00A00093;
        // ADDI x2, x0, 20
        imem[1] = 32'h01400113;
        // ADD  x3, x1, x2  (x3 = 30)
        imem[2] = 32'h002081B3;
        // ADDI x4, x0, 5
        imem[3] = 32'h00500213;
        // ADD  x5, x3, x4  (x5 = 35)
        imem[4] = 32'h004182B3;
        // NOPs
        for (int k = 5; k < 1024; k++) begin
            imem[k] = 32'h00000013; // NOP (ADDI x0, x0, 0)
        end
    end

    // Synchronous dual-word instruction fetch
    always_ff @(posedge clk) begin
        imem_rdata[31:0]  <= imem[imem_addr[11:2]];
        imem_rdata[63:32] <= imem[imem_addr[11:2] + 1];
    end

    // -------------------------------------------------------------------------
    // On-Chip Data Memory (1024 x 32-bit words = 4KB, byte-write enabled)
    // Inferred as Block RAM with byte enables
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [31:0] dmem [0:1023];

    // Synchronous write with byte enables
    always_ff @(posedge clk) begin
        if (dmem_wr_en && (dmem_addr < 32'h0000_1000)) begin
            if (dmem_byte_en[0]) dmem[dmem_addr[11:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_byte_en[1]) dmem[dmem_addr[11:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_byte_en[2]) dmem[dmem_addr[11:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_byte_en[3]) dmem[dmem_addr[11:2]][31:24] <= dmem_wdata[31:24];
        end
    end

    // Synchronous read
    always_ff @(posedge clk) begin
        if (dmem_rd_en) begin
            dmem_rdata <= dmem[dmem_addr[11:2]];
        end else begin
            dmem_rdata <= 32'h0;
        end
    end

    // -------------------------------------------------------------------------
    // Memory-Mapped I/O and Debug LED Output
    // Switch selects what to display on the 16 LEDs:
    //   sw[3:0] = 0 -> LEDs show lower 16 bits of PC
    //   sw[3:0] = 1 -> LEDs show Register x1
    //   sw[3:0] = 2 -> LEDs show Register x2
    //   sw[3:0] = 3 -> LEDs show Register x3 (should be 30 = 0x001E)
    //   sw[3:0] = 5 -> LEDs show Register x5 (should be 35 = 0x0023)
    // -------------------------------------------------------------------------
    logic [15:0] led_display;

    always_comb begin
        case (sw[3:0])
            4'd0: led_display = imem_addr[15:0];
            4'd1: led_display = u_core.u_regfile.rf[1][15:0];
            4'd2: led_display = u_core.u_regfile.rf[2][15:0];
            4'd3: led_display = u_core.u_regfile.rf[3][15:0];
            4'd4: led_display = u_core.u_regfile.rf[4][15:0];
            4'd5: led_display = u_core.u_regfile.rf[5][15:0];
            default: led_display = {u_core.rob_full, u_core.iq_full, u_core.intra_dep, 13'd0};
        endcase
    end

    assign led = led_display;

endmodule : fpga_top
