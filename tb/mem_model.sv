// ============================================================
// mem_model.sv
// Behavioral (non-synthesizable) dual-port instruction and data
// memory model for simulation of the Superscalar RV32I core.
// 64KB I-Memory (64-bit wide read) + 64KB D-Memory (32-bit).
// ============================================================
`timescale 1ns/1ps

module instruction_memory #(
  parameter int MEM_DEPTH   = 16384,     // Number of 32-bit words = 64KB
  parameter string HEX_FILE = "imem.hex" // Optional hex initialization file
)(
  input  logic          clk,
  input  logic [31:0]   addr,       // Byte address (8-byte aligned for dual-fetch)
  output logic [63:0]   rdata       // Two instructions: [31:0]=inst0, [63:32]=inst1
);
  // Internal word-addressed storage
  logic [31:0] mem [0:MEM_DEPTH-1];

  // Load hex file if provided
  initial begin
    for (int i = 0; i < MEM_DEPTH; i++) mem[i] = 32'h0000_0013; // NOP (ADDI x0,x0,0)
    // Uncomment to load program:
    // $readmemh(HEX_FILE, mem);
  end

  // Asynchronous dual read (combinational, like a ROM / cache)
  // addr[2] selects word within 8-byte pair; we always return the pair.
  assign rdata[31: 0] = mem[addr[31:2]];         // inst at addr (word index)
  assign rdata[63:32] = mem[addr[31:2] + 1];     // inst at addr+4

endmodule


module data_memory #(
  parameter int MEM_DEPTH = 16384  // 64KB data memory
)(
  input  logic        clk,
  input  logic        rst_n,
  // Read port (load)
  input  logic [31:0] addr,
  input  logic        rd_en,
  output logic [31:0] rdata,
  // Write port (store)
  input  logic        wr_en,
  input  logic [3:0]  byte_en,   // Byte enables: [3]=byte3, [2]=byte2, [1]=byte1, [0]=byte0
  input  logic [31:0] wdata
);
  logic [7:0] mem [0:MEM_DEPTH*4-1];  // Byte-addressed storage

  // Synchronous write with byte enables
  always_ff @(posedge clk) begin
    if (wr_en) begin
      if (byte_en[0]) mem[addr + 0] <= wdata[7:0];
      if (byte_en[1]) mem[addr + 1] <= wdata[15:8];
      if (byte_en[2]) mem[addr + 2] <= wdata[23:16];
      if (byte_en[3]) mem[addr + 3] <= wdata[31:24];
    end
  end

  // Asynchronous read (word assembled from bytes)
  always_comb begin
    if (rd_en)
      rdata = {mem[addr+3], mem[addr+2], mem[addr+1], mem[addr]};
    else
      rdata = 32'h0;
  end

  // Initialize to zero
  initial begin
    for (int i = 0; i < MEM_DEPTH*4; i++) mem[i] = 8'h00;
  end

endmodule
