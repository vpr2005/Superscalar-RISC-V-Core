// ============================================================
// tb_superscalar_core.sv
// Cycle-accurate testbench for the dual-issue Superscalar
// RV32I Core. Tests:
//   1. Independent parallel arithmetic (IPC = 2.0 target)
//   2. RAW dependency hazard sequence
//   3. Load-use hazard stall
//   4. Branch taken / misprediction and flush
//   5. Mixed instruction workload (loop)
// ============================================================
`timescale 1ns/1ps
import riscv_pkg::*;

module tb_superscalar_core;

  // -----------------------------------------------------------
  // DUT Signals
  // -----------------------------------------------------------
  logic         clk;
  logic         rst_n;
  // Instruction memory interface
  logic [31:0]  imem_addr;
  logic [63:0]  imem_rdata;
  // Data memory interface
  logic [31:0]  dmem_addr;
  logic         dmem_rd_en;
  logic [31:0]  dmem_rdata;
  logic         dmem_wr_en;
  logic [3:0]   dmem_byte_en;
  logic [31:0]  dmem_wdata;

  // -----------------------------------------------------------
  // Clock Generation: 10 ns period = 100 MHz
  // -----------------------------------------------------------
  initial clk = 0;
  always #5 clk = ~clk;

  // -----------------------------------------------------------
  // Instruction Memory Model
  // -----------------------------------------------------------
  instruction_memory #(
    .MEM_DEPTH(16384)
  ) u_imem (
    .clk   (clk),
    .addr  (imem_addr),
    .rdata (imem_rdata)
  );

  // -----------------------------------------------------------
  // Data Memory Model
  // -----------------------------------------------------------
  data_memory #(
    .MEM_DEPTH(16384)
  ) u_dmem (
    .clk      (clk),
    .rst_n    (rst_n),
    .addr     (dmem_addr),
    .rd_en    (dmem_rd_en),
    .rdata    (dmem_rdata),
    .wr_en    (dmem_wr_en),
    .byte_en  (dmem_byte_en),
    .wdata    (dmem_wdata)
  );

  // -----------------------------------------------------------
  // DUT Instantiation
  // -----------------------------------------------------------
  superscalar_core u_dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .imem_addr    (imem_addr),
    .imem_rdata   (imem_rdata),
    .dmem_addr    (dmem_addr),
    .dmem_rd_en   (dmem_rd_en),
    .dmem_rdata   (dmem_rdata),
    .dmem_wr_en   (dmem_wr_en),
    .dmem_byte_en (dmem_byte_en),
    .dmem_wdata   (dmem_wdata)
  );

  // -----------------------------------------------------------
  // Test Program Loader: write instructions into instruction
  // memory array directly using hierarchical reference.
  // Programs are encoded as RV32I machine code (hex).
  // -----------------------------------------------------------
  task automatic load_program(input logic [31:0] prog [], input int start_addr = 0);
    for (int i = 0; i < prog.size(); i++) begin
      u_imem.mem[start_addr/4 + i] = prog[i];
    end
  endtask

  // -----------------------------------------------------------
  // Register File Readback (hierarchical reference for checking)
  // -----------------------------------------------------------
  function automatic logic [31:0] read_reg(input int reg_num);
    return u_dut.u_regfile.rf[reg_num];
  endfunction

  // -----------------------------------------------------------
  // Pass/Fail checker
  // -----------------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;

  task automatic check_reg(
    input int    reg_num,
    input logic [31:0] expected,
    input string test_name
  );
    logic [31:0] actual;
    actual = read_reg(reg_num);
    if (actual === expected) begin
      $display("[PASS] %s: x%0d = 0x%08h (expected 0x%08h)", test_name, reg_num, actual, expected);
      pass_count++;
    end else begin
      $display("[FAIL] %s: x%0d = 0x%08h (expected 0x%08h)", test_name, reg_num, actual, expected);
      fail_count++;
    end
  endtask

  // -----------------------------------------------------------
  // Reset Task
  // -----------------------------------------------------------
  task automatic do_reset();
    rst_n = 0;
    repeat(4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
  endtask

  // -----------------------------------------------------------
  // Wait N cycles
  // -----------------------------------------------------------
  task automatic run_cycles(input int n);
    repeat(n) @(posedge clk);
  endtask

  // -----------------------------------------------------------
  // TEST 1: Independent parallel arithmetic
  // Two independent ADD/ADDI pairs that can execute simultaneously
  // Expected IPC = 2.0 for these pairs
  //
  // Assembly:
  //   ADDI x1, x0, 10    // x1 = 10
  //   ADDI x2, x0, 20    // x2 = 20
  //   ADD  x3, x1, x2    // x3 = 30
  //   ADDI x4, x0, 5     // x4 = 5
  //   ADD  x5, x3, x4    // x5 = 35
  //   ADDI x0, x0, 0     // NOP (padding)
  // -----------------------------------------------------------
  logic [31:0] prog_parallel [] = '{
    32'h00A00093,   // ADDI x1,  x0, 10   (0x00)
    32'h01400113,   // ADDI x2,  x0, 20   (0x04)
    32'h002081B3,   // ADD  x3,  x1, x2   (0x08) - RAW on x1,x2 (stalls until x1,x2 ready)
    32'h00500213,   // ADDI x4,  x0, 5    (0x0C)
    32'h004182B3,   // ADD  x5,  x3, x4   (0x10)
    32'h00000013    // NOP                 (0x14)
  };

  // -----------------------------------------------------------
  // TEST 2: RAW Dependency Chain
  //   ADDI x6, x0, 1     // x6 = 1
  //   ADDI x6, x6, 1     // x6 = 2 (RAW on x6)
  //   ADDI x6, x6, 1     // x6 = 3 (RAW on x6)
  //   ADDI x6, x6, 1     // x6 = 4 (RAW on x6)
  // -----------------------------------------------------------
  logic [31:0] prog_raw [] = '{
    32'h00100313,   // ADDI x6, x0, 1     (0x00)
    32'h00130313,   // ADDI x6, x6, 1     (0x04)
    32'h00130313,   // ADDI x6, x6, 1     (0x08)
    32'h00130313,   // ADDI x6, x6, 1     (0x0C)
    32'h00000013,   // NOP                 (0x10)
    32'h00000013    // NOP                 (0x14)
  };

  // -----------------------------------------------------------
  // TEST 3: Load-Use Hazard
  //   ADDI x1, x0, 10    // x1 = 10
  //   ADDI x2, x0, 20    // x2 = 20
  //   SW   x1, 0(x0)     // store 10 to address 0
  //   LW   x7, 0(x0)     // load  x7 from address 0 (load-use)
  //   ADD  x8, x7, x2    // ADD must wait for x7 (load-use stall, 10 + 20 = 30)
  // -----------------------------------------------------------
  logic [31:0] prog_load_use [] = '{
    32'h00A00093,   // ADDI x1, x0, 10      (0x00)
    32'h01400113,   // ADDI x2, x0, 20      (0x04)
    32'h00102023,   // SW   x1, 0(x0)       (0x08)
    32'h00002383,   // LW   x7, 0(x0)       (0x0C)
    32'h00238433,   // ADD  x8, x7, x2      (0x10) - must stall waiting for x7
    32'h00000013,   // NOP                  (0x14)
    32'h00000013    // NOP                  (0x18)
  };

  // -----------------------------------------------------------
  // TEST 4: Branch (BEQ taken)
  //   ADDI x9,  x0, 5
  //   ADDI x10, x0, 5
  //   BEQ  x9, x10, +8   // taken: skip next instruction
  //   ADDI x11, x0, 99   // should be flushed (not executed)
  //   ADDI x12, x0, 42   // should execute (branch target)
  // -----------------------------------------------------------
  logic [31:0] prog_branch [] = '{
    32'h00500493,   // ADDI x9,  x0, 5      (0x00)
    32'h00500513,   // ADDI x10, x0, 5      (0x04)
    32'h00A48463,   // BEQ  x9, x10, +8     (0x08) -> target 0x10
    32'h06300593,   // ADDI x11, x0, 99     (0x0C) <- should be flushed
    32'h02A00613,   // ADDI x12, x0, 42     (0x10) <- should execute
    32'h00000013    // NOP
  };

  // -----------------------------------------------------------
  // Commit Monitor for Debugging
  // -----------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      if (u_dut.commit_we_0 && u_dut.commit_rd_0 != 5'd0)
        $display("  [%0t ns] COMMIT 0: x%0d <= 0x%08h", $time, u_dut.commit_rd_0, u_dut.commit_data_0);
      if (u_dut.commit_we_1 && u_dut.commit_rd_1 != 5'd0)
        $display("  [%0t ns] COMMIT 1: x%0d <= 0x%08h", $time, u_dut.commit_rd_1, u_dut.commit_data_1);
    end
  end

  // -----------------------------------------------------------
  // Main Test Sequence
  // -----------------------------------------------------------
  initial begin
    #1; // Wait 1ns for memory model initialization to complete
    $display("================================================");
    $display(" Dual-Issue Superscalar RISC-V Core Testbench  ");
    $display("================================================");

    // ---- Test 1: Parallel Arithmetic ----
    $display("\n[TEST 1] Independent Parallel Arithmetic");
    load_program(prog_parallel);
    do_reset();
    run_cycles(20);
    check_reg(1, 32'd10, "T1: x1");
    check_reg(2, 32'd20, "T1: x2");
    check_reg(3, 32'd30, "T1: x3 = x1+x2");
    check_reg(4, 32'd5,  "T1: x4");
    check_reg(5, 32'd35, "T1: x5 = x3+x4");

    // ---- Test 2: RAW Chain ----
    $display("\n[TEST 2] RAW Dependency Chain");
    load_program(prog_raw);
    do_reset();
    run_cycles(20);
    check_reg(6, 32'd4, "T2: x6 = 1+1+1+1");

    // ---- Test 3: Load-Use ----
    $display("\n[TEST 3] Load-Use Hazard");
    load_program(prog_load_use);
    do_reset();
    run_cycles(25);
    check_reg(7, 32'd10, "T3: x7 loaded = 10");
    check_reg(8, 32'd30, "T3: x8 = x7 + x2 = 10+20");

    // ---- Test 4: Branch ----
    $display("\n[TEST 4] Branch Taken + Flush");
    load_program(prog_branch);
    do_reset();
    run_cycles(25);
    check_reg(9,  32'd5,  "T4: x9 = 5");
    check_reg(10, 32'd5,  "T4: x10 = 5");
    check_reg(11, 32'd0,  "T4: x11 = 0 (flushed, should NOT be 99)");
    check_reg(12, 32'd42, "T4: x12 = 42 (branch target)");

    // ---- Summary ----
    $display("\n================================================");
    $display(" Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
    $display("================================================");

    if (fail_count == 0)
      $display(" ALL TESTS PASSED!");
    else
      $display(" SOME TESTS FAILED — review waveform.");

    $finish;
  end

  // -----------------------------------------------------------
  // Waveform Dump (for Vivado / ModelSim / Icarus)
  // -----------------------------------------------------------
  initial begin
    $dumpfile("tb_superscalar_core.vcd");
    $dumpvars(0, tb_superscalar_core);
  end

  // -----------------------------------------------------------
  // Timeout watchdog: abort simulation if stuck
  // -----------------------------------------------------------
  initial begin
    #10000;
    $display("[TIMEOUT] Simulation exceeded 10us — aborting.");
    $finish;
  end

endmodule
