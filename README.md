# Dual-Issue Superscalar RISC-V Core (RV32I)

A synthesizable, cycle-accurate implementation of a **2-way superscalar, dynamically-scheduled RV32I processor core** in SystemVerilog, targeting Xilinx FPGA (Vivado) and ASIC flows.

---

## Architecture at a Glance

```
PC ──► [ FETCH STAGE ]──► [ DECODE STAGE ]──► [ ISSUE QUEUE ]
           (2x32b)           (2x Decoder)       (8-entry IQ)
                                                    │       │
                                              ┌─────▼─┐ ┌───▼──────┐
                                              │ EX0   │ │  EX1     │
                                              │ ALU0  │ │ ALU1+LSU │
                                              │ BRU0  │ │ BRU1     │
                                              └───┬───┘ └────┬─────┘
                                                  │          │
                                          ◄───────┘──────────┘
                                         Forwarding / Wakeup Buses
                                                  │
                                         [ REORDER BUFFER ]
                                           (in-order commit)
                                                  │
                                          [ REGISTER FILE ]
                                            (4R / 2W ports)
```

| Feature | Specification |
|:--|:--|
| ISA | RISC-V RV32I (Base 32-bit Integer) |
| Issue Width | 2 instructions/cycle (dual-issue) |
| Scheduling | Dynamic out-of-order issue via 8-entry Issue Queue |
| Commit | In-order via 16-entry Reorder Buffer (ROB) |
| Register File | 32 × 32-bit, 4 Read / 2 Write ports |
| Hazard Handling | Forwarding network + load-use stall + branch flush |
| I-Memory Bus | 64-bit wide (2 × 32-bit instruction per cycle) |
| Target | Xilinx Artix-7 (xc7a35t), Vivado 2022.x+ |

---

## Directory Structure

```
Superscaler_RISCV/
├── rtl/
│   ├── riscv_pkg.sv            ← ISA constants & shared pipeline structs (package)
│   ├── alu.sv                  ← 32-bit combinational ALU
│   ├── branch_unit.sv          ← Branch evaluation & target computation
│   ├── regfile.sv              ← 4R/2W multi-ported register file
│   ├── fetch_stage.sv          ← Dual-instruction PC + fetch
│   ├── decode_stage.sv         ← Dual decoder + intra-pair dependency check
│   ├── load_store_unit.sv      ← Memory AGU, byte-enables, sign-extension
│   ├── forwarding_unit.sv      ← EX/MEM → Issue bypass network
│   ├── hazard_unit.sv          ← Stall, bubble, flush control
│   ├── issue_queue.sv          ← Dynamic instruction window (IQ_DEPTH=8)
│   ├── reorder_buffer.sv       ← In-order commit buffer (ROB_DEPTH=16)
│   └── superscalar_core.sv     ← Top-level integration
├── tb/
│   ├── mem_model.sv            ← Behavioral I-mem (64b) + D-mem models
│   └── tb_superscalar_core.sv  ← Self-checking testbench (4 test cases)
├── superscalar_riscv.tcl       ← Vivado project + simulation setup script
└── README.md
```

---

## Getting Started

### 1. Open in Vivado
```tcl
# In Vivado Tcl Console:
source superscalar_riscv.tcl
```

### 2. Run Simulation
```tcl
launch_simulation
run all
```

### 3. Run Synthesis & Implementation

#### Option A: Out-Of-Context (OOC) Mode (Evaluates Core Area & Timing directly)
Since `superscalar_core` has 200 memory bus pins (which exceeds the 106 physical package pins of the Artix-7 CPG236), use Out-Of-Context synthesis to measure core LUTs, FFs, and $F_{\max}$ without pin overutilization:
```tcl
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} [get_runs synth_1]
reset_run synth_1
launch_runs impl_1 -jobs 4
wait_on_run impl_1
open_run impl_1
report_utilization -file utilization.rpt
report_timing_summary -file timing.rpt
```

#### Option B: Full FPGA Board Implementation (Generates Bitstream with `fpga_top.sv`)
Set `fpga_top` as top module to embed the core with on-chip BRAM memory and board I/O (buttons, switches, LEDs):
```tcl
set_property top fpga_top [current_fileset]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

### 4. Using Icarus Verilog (Open-Source)
```bash
iverilog -g2012 -I rtl/ \
  rtl/riscv_pkg.sv \
  rtl/alu.sv rtl/branch_unit.sv rtl/regfile.sv \
  rtl/fetch_stage.sv rtl/decode_stage.sv \
  rtl/load_store_unit.sv rtl/forwarding_unit.sv \
  rtl/hazard_unit.sv rtl/issue_queue.sv \
  rtl/reorder_buffer.sv rtl/superscalar_core.sv \
  tb/mem_model.sv tb/tb_superscalar_core.sv \
  -o sim_out && vvp sim_out
```

---

## Test Coverage

| Test | Description | Expected |
|:--|:--|:--|
| T1 | Independent parallel arithmetic | IPC ≈ 2.0, x5 = 35 |
| T2 | RAW dependency chain | x6 = 4 after 4 dependent ADDIs |
| T3 | Load-use hazard | x7 loaded correctly, x8 = x7 + x2 |
| T4 | Branch taken + flush | x11 = 0 (flushed), x12 = 42 (target executed) |

---

## Pipeline Timing (Ideal)

```
Cycle:    1      2      3      4      5      6
FETCH  [I0,I1][I2,I3][I4,I5]
DECODE        [I0,I1][I2,I3][I4,I5]
ISSUE                [I0,I1][I2,I3][I4,I5]
EX0                         [I0]   [I2]   [I4]
EX1                         [I1]   [I3]   [I5]
WB                                 [I0]   [I1]
```

---

## Module Interfaces Summary

### `superscalar_core` (Top-Level)
| Port | Direction | Width | Description |
|:--|:--|:--|:--|
| `clk` | in | 1 | System clock |
| `rst_n` | in | 1 | Active-low synchronous reset |
| `imem_addr` | out | 32 | Instruction fetch address |
| `imem_rdata` | in | 64 | Two instruction words |
| `dmem_addr` | out | 32 | Data memory address |
| `dmem_rd_en` | out | 1 | Load enable |
| `dmem_rdata` | in | 32 | Load data |
| `dmem_wr_en` | out | 1 | Store enable |
| `dmem_byte_en` | out | 4 | Store byte enables |
| `dmem_wdata` | out | 32 | Store data |
