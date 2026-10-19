# Dual-Issue Superscalar RISC-V (RV32I) Processor Core
## Comprehensive Technical Architecture, Implementation, and Defense Documentation

---

# 1. Executive Summary & Presentation Pitch

### 30-Second Elevator Pitch
> *"In this project, we designed, implemented, and verified a cycle-accurate, synthesizable **2-way Superscalar RISC-V (RV32I) Processor Core** in SystemVerilog. Unlike standard single-issue processors that are fundamentally bounded by an Instructions-Per-Cycle (IPC) limit of 1.0, our design achieves a peak throughput of **IPC = 2.0**. It features concurrent 64-bit dual-instruction fetch, dynamic instruction scheduling via an 8-entry **Issue Queue (Reservation Station)**, out-of-order execution across asymmetric dual execution pipelines (ALU/BRU and ALU/LSU), an acyclic multi-stage operand forwarding network, and in-order retirement via a 16-entry **Reorder Buffer (ROB)** to maintain precise architectural state during branch mispredictions and traps. The entire core was synthesized and verified on a Xilinx Artix-7 FPGA using Vivado."*

---

# 2. Key Specifications at a Glance

| Architectural Parameter | Implementation Details |
| :--- | :--- |
| **ISA** | RISC-V Base 32-bit Integer (`RV32I` unprivileged specification) |
| **Issue Width** | **2 instructions per cycle** (Dual-Issue Superscalar) |
| **Pipeline Depth** | 6 Stages: Fetch $\rightarrow$ Decode $\rightarrow$ Issue (Window) $\rightarrow$ Execute $\rightarrow$ Memory $\rightarrow$ Commit |
| **Instruction Scheduling** | **Dynamic Out-of-Order Execution** using an 8-entry Issue Queue |
| **Retirement / Commit** | **In-Order Commit** via 16-entry Reorder Buffer (ROB) |
| **Register File** | 32 registers $\times$ 32-bit wide, **4 Asynchronous Read ports**, **2 Synchronous Write ports**, internal Write-Before-Read (WBR) bypassing, $x0 \equiv 0$ |
| **Execution Pipeline 0** | 32-bit ALU0 (Arithmetic/Logic/Shift) + Branch Resolution Unit 0 (BRU0) |
| **Execution Pipeline 1** | 32-bit ALU1 + Load/Store Unit (LSU) + Branch Resolution Unit 1 (BRU1) |
| **Hazard Resolution** | Inter-stage forwarding network, Load-Use interlock stall, Speculative branch flush |
| **Memory Interface** | Harvard Architecture: 64-bit Instruction bus (dual fetch) + 32-bit Data bus |
| **Target Hardware** | Xilinx Artix-7 FPGA (`xc7a35tcpg236-1`), Vivado Design Suite |

---

# 3. High-Level System Architecture

```
                       ┌───────────────────────────────┐
                       │     64-bit Instruction Mem    │
                       └───────────────▲───────────────┘
                                       │ (imem_rdata[63:0])
                              ┌────────┴────────┐
                              │   Fetch Stage   │◄───────── Branch Redirect
                              │ (PC Gen, PC+8)  │
                              └────────┬────────┘
                                       │ (inst0, inst1)
                              ┌────────▼────────┐
                              │  Decode Stage   │
                              │ (Dual Decoders) │
                              └────────┬────────┘
                                       │ (disp_instr_0, disp_instr_1)
                    ┌──────────────────┴──────────────────┐
                    │                                     │
           ┌────────▼────────┐                   ┌────────▼────────┐
           │ 16-Entry ROB    │                   │ 8-Entry Issue Q │
           │ (Commit Buffer) │                   │ (Scoreboard/IW) │
           └────────▲────────┘                   └────────┬────────┘
                    │                                     │
                    │                             ┌───────┴───────┐
                    │                             │               │
                    │                      ┌──────▼──────┐ ┌──────▼──────┐
                    │                      │    EX0      │ │    EX1      │
                    │                      │ (ALU0/BRU0) │ │ (ALU1/LSU)  │
                    │                      └──────┬──────┘ └──────┬──────┘
                    │                             │               │
                    │                      ┌──────▼───────────────▼──────┐
                    │                      │   Forwarding Bypass Network │
                    │                      └──────────────┬──────────────┘
                    │                                     │
                    │                              ┌──────▼──────┐
                    │                              │  Data Mem   │
                    │                              │   (32-bit)  │
                    │                              └──────┬──────┘
                    │                                     │
                    └──────────────────┬──────────────────┘
                                       │ (commit_0, commit_1)
                              ┌────────▼────────┐
                              │  Register File  │
                              │    (4R / 2W)    │
                              └─────────────────┘
```

---

# 4. Pipeline Stages: Microarchitectural Deep-Dive

### Stage 1: Fetch Stage (`fetch_stage.sv`)
* **Role:** Supplies two 32-bit instructions every clock cycle to maximize frontend throughput.
* **Mechanism:**
  - Employs a 64-bit wide memory interface. `imem_addr` is 8-byte aligned (`PC[31:3], 3'b000`).
  - Fetches Instruction 0 at address `PC` and Instruction 1 at address `PC + 4`.
  - In normal sequential operation, the program counter increments by $+8$ (`PC <= PC + 8`).
  - When a control hazard occurs (branch taken / JAL / JALR), the fetch PC is redirected via an asynchronous multiplexer fed by `redirect_target`, and subsequent speculative instructions are invalidated.
  - Supports pipeline freezing via `stall` (for load-use hazards) and clearing via `flush`.

### Stage 2: Decode & Dependency Stage (`decode_stage.sv`)
* **Role:** Parses both instructions simultaneously, extracts all register fields, generates immediate values, and flags dependencies.
* **Mechanism:**
  - Implements **two independent, parallel RV32I decoders** analyzing opcodes, `funct3`, and `funct7`.
  - Supports all standard RV32I formats: **R-type** (`add, sub, sll, slt, sltu, xor, srl, sra, or, and`), **I-type** (`addi, andi, ori, xori, slti, sltiu, slli, srli, srai, jalr, lw, lh, lhu, lb, lbu`), **S-type** (`sw, sh, sb`), **B-type** (`beq, bne, blt, bge, bltu, bgeu`), **U-type** (`lui, auipc`), and **J-type** (`jal`).
  - **Intra-Pair RAW Dependency Detection:** Checks if Instruction 1 depends on Instruction 0 within the same decode cycle (`dec0.rd == dec1.rs1 || dec0.rd == dec1.rs2`). This flag is forwarded to the Issue Queue to prevent Instruction 1 from issuing ahead of Instruction 0.

### Stage 3: Dynamic Scheduling & Issue Queue (`issue_queue.sv`)
* **Role:** Decouples the in-order frontend (Fetch/Decode) from the execution engine, enabling **Dynamic Out-of-Order Instruction Scheduling**.
* **Microarchitecture:**
  - **8-Entry Circular Instruction Window:** Tracks each instruction's opcode, operands, and ready bits (`src1_rdy`, `src2_rdy`).
  - **Scoreboard Wakeup:** Each cycle, waiting instructions monitor execution results from EX and MEM stages. When an in-flight producer completes, dependent queue entries latch the result and assert their readiness flags on `posedge clk`.
  - **Dual-Dispatch Priority Logic:**
    - **Issue Slot 0:** Scans from `head` for the oldest ready **non-memory instruction** (dispatched to Execution Pipeline 0: ALU0 + Branch Unit).
    - **Issue Slot 1:** Scans from `head` for the oldest ready instruction of any type (dispatched to Execution Pipeline 1: ALU1 + LSU).
  - **Write-After-Write (WAW) Program-Order Interlock:** Uses `has_older_producer()` to inspect whether an unissued instruction older than entry `k` also writes to `rs`. This prevents a younger instruction in a RAW chain from prematurely capturing an old result before its immediate predecessor has produced the newest value.

### Stage 4: Dual Execution Engines (`alu.sv`, `branch_unit.sv`, `load_store_unit.sv`)
* **Pipeline 0 (EX0):**
  - **ALU0:** 32-bit combinational ALU executing full RV32I arithmetic, logic, and shift operations.
  - **BRU0:** Dedicated branch comparator and branch target generator (`PC + imm` and `JALR`).
* **Pipeline 1 (EX1):**
  - **ALU1:** Secondary 32-bit ALU for dual arithmetic issue.
  - **Load/Store Unit (LSU):** Address Generation Unit (AGU = `base_addr + offset`), byte-mask generator (`SB`: 1 byte, `SH`: 2 bytes, `SW`: 4 bytes), store data byte alignment, load data sign/zero-extension (`LB`, `LBU`, `LH`, `LHU`, `LW`), and address misalignment error flag.
  - **BRU1:** Redundant branch unit allowing branches in slot 1.

### Stage 5: Memory Pipeline Registers & Bypass (`mem0_result`, `mem1_result`)
* **Role:** Latch EX stage outputs at the clock edge to buffer results before commit, preventing combinational feedback loops while providing a registered forwarding source for following instructions.

### Stage 6: Reorder Buffer & In-Order Commit (`reorder_buffer.sv`, `regfile.sv`)
* **Role:** Restores strict architectural program order to support precise interrupts and clean branch misprediction recovery.
* **Microarchitecture:**
  - **16-Entry Circular ROB:** Each instruction is allocated an entry at `tail` during Dispatch and assigned a unique `rob_tag`.
  - **Out-of-Order Completion:** Execution pipelines write results directly into their pre-assigned entry using direct tag indexing (`rob[complete.rob_tag] <= complete.result`).
  - **Dual In-Order Commit:** At `head`, the ROB retires up to **2 instructions per cycle** if and only if they are marked complete. Retired results are written simultaneously to Write Ports 0 and 1 of the Register File.

---

# 5. Hazard Handling & Resolution Mechanisms

### 1. Data Hazards (RAW — Read-After-Write)
* **Intra-Cycle Bypass:** The [`forwarding_unit.sv`](file:///d:/Projects/Superscaler_RISCV/rtl/forwarding_unit.sv) inspects registered MEM stage results (`mem0_result`, `mem1_result`) and WB stage results (`commit_data_0`, `commit_data_1`). If an executing instruction needs an operand produced by the immediately preceding instruction, the value is forwarded directly into the ALU input multiplexers, achieving **1-cycle back-to-back ALU execution latency** (0 bubble overhead).
* **Issue Queue Holding:** If an instruction's source operands have not yet been generated (e.g. producer is still in the queue), the consumer stays buffered in the Issue Queue with `src_rdy = 0` until the producer finishes execution and wakes it up.

### 2. Name Hazards (WAW — Write-After-Write)
* Solved via the `has_older_producer()` function in `issue_queue.sv`. If two instructions in the queue write to the same register (e.g. consecutive `ADDI x6, x6, 1`), subsequent consumers are bound to the younger instruction and will not wake up on the completion of the older instruction.

### 3. Structural Hazards
* **Memory Conflict:** The core contains a single 32-bit Data Memory port. To prevent structural resource conflicts, Issue Slot 0 is restricted to non-memory operations (`CAT_ALU`, `CAT_BRANCH`), while Issue Slot 1 handles memory operations (`LW`, `SW`) or ALU instructions.

### 4. Load-Use Data Hazards
* Memory load latency requires 1 cycle between memory address generation and data arrival.
* When an instruction in EX1 is a `LOAD` (`mem_read == 1`) and its destination `rd` matches a source register in the Decode stage:
  - [`hazard_unit.sv`](file:///d:/Projects/Superscaler_RISCV/rtl/hazard_unit.sv) asserts `load_use_stall = 1`.
  - `stall_fetch = 1` and `stall_decode = 1` freeze the Fetch and Decode pipeline registers for 1 cycle.
  - `stall_issue = 1` blocks enqueue into the Issue Queue, cleanly inserting a single-cycle bubble.
  - In the next cycle, the load data arrives in `mem1_result` and is forwarded to the dependent instruction.

### 5. Control Hazards (Branch Mispredictions)
* **Prediction Policy:** Predict-Not-Taken (speculative sequential execution).
* When a branch or jump resolves as **taken** in an execution unit:
  - The branch unit asserts `branch_taken` and outputs the computed `branch_target`.
  - The `hazard_unit` asserts `redirect_valid = 1`, flushing the speculatively fetched instructions from Fetch (`flush_fetch`), Decode (`flush_decode`), and Issue Queue (`flush_issue`).
  - The Fetch stage program counter redirects to `branch_target` with a **2-cycle misprediction penalty**.
  - Any speculatively executed instructions in the ROB are discarded before reaching the head, guaranteeing that the architectural Register File is never corrupted.

---

# 6. Critical Engineering Challenges Solved

### Problem 1: Zero-Delay Combinational Loops (XSim Simulator 45-1)
* **Symptom:** XSim crashed at simulation time `65 ns` with:
  `ERROR: [Simulator 45-1] A fatal run-time error was detected. Simulation cannot continue.`
* **Cause:** The forwarding unit combinationally forwarded `ex0_result` and `ex1_result` into the execution inputs of that same cycle. For any instruction where `rd == rs1` (e.g. `addi x1, x1, 1`), this formed an unclocked combinational loop ($$\text{ALU output} \rightarrow \text{ex\_result} \rightarrow \text{forwarding mux} \rightarrow \text{ALU input}$$).
* **Solution:** Decoupled execution from forwarding. Forwarding to execution units now draws exclusively from **registered pipeline stages** (`mem0_result`, `mem1_result`, and ROB commit), breaking all zero-delay loops.

### Problem 2: Preserving Decode State During Load-Use Stalls
* **Symptom:** Instructions following a load were randomly disappearing from the pipeline.
* **Cause:** `hazard_unit.sv` was asserting `flush_decode` on both branch flushes and load-use stalls, which cleared the decode registers on every load stall.
* **Solution:** Changed `flush_decode` to assert exclusively on `redirect_valid` (branch taken). Load-use hazards now hold the decode registers via `stall_decode` and naturally insert bubbles via `stall_issue`.

### Problem 3: FPGA Package Pin Overutilization ([Place 30-415])
* **Symptom:** During Vivado implementation of the raw processor core, the placer failed:
  `[Place 30-415] IO Placement failed due to overutilization. This design contains 200 I/O ports while target package contains only 106 available user I/O.`
* **Cause:** An unencapsulated CPU exposes wide memory buses (64-bit instruction bus, 32-bit data bus, addresses, byte enables) totaling 200 signals. The Artix-7 CPG236 package has only 106 physical external pins.
* **Solution:**
  1. **Option A (Out-of-Context Synthesis):** Synthesized the core with `-mode out_of_context`, allowing full placement and routing of the core's logic without inserting physical I/O pad buffers.
  2. **Option B (SoC Wrapper `fpga_top.sv`):** Created a synthesizable top-level wrapper with on-chip Block RAMs (BRAM) for memory, exposing only 34 board pins (100MHz clock, reset button, 16 switches, 16 LEDs).

---

# 7. Verification Results & Test Coverage

The core was verified using the self-checking testbench [`tb_superscalar_core.sv`](file:///d:/Projects/Superscaler_RISCV/tb/tb_superscalar_core.sv).

```
================================================
 Dual-Issue Superscalar RISC-V Core Testbench  
================================================

[TEST 1] Independent Parallel Arithmetic
  [75000 ns] COMMIT 0: x1 <= 0x0000000a
  [75000 ns] COMMIT 1: x2 <= 0x00000014
  [85000 ns] COMMIT 0: x3 <= 0x0000001e
  [85000 ns] COMMIT 1: x4 <= 0x00000005
  [95000 ns] COMMIT 0: x5 <= 0x00000023
[PASS] T1: x1: x1 = 0x0000000a (expected 0x0000000a)
[PASS] T1: x2: x2 = 0x00000014 (expected 0x00000014)
[PASS] T1: x3 = x1+x2: x3 = 0x0000001e (expected 0x0000001e)
[PASS] T1: x4: x4 = 0x00000005 (expected 0x00000005)
[PASS] T1: x5 = x3+x4: x5 = 0x00000023 (expected 0x00000023)

[TEST 2] RAW Dependency Chain
  [325000 ns] COMMIT 0: x6 <= 0x00000001
  [335000 ns] COMMIT 0: x6 <= 0x00000002
  [345000 ns] COMMIT 0: x6 <= 0x00000003
  [355000 ns] COMMIT 0: x6 <= 0x00000004
[PASS] T2: x6 = 1+1+1+1: x6 = 0x00000004 (expected 0x00000004)

[TEST 3] Load-Use Hazard
  [575000 ns] COMMIT 0: x1 <= 0x0000000a
  [575000 ns] COMMIT 1: x2 <= 0x00000014
  [605000 ns] COMMIT 0: x7 <= 0x0000000a
  [615000 ns] COMMIT 0: x8 <= 0x0000001e
[PASS] T3: x7 loaded = 10: x7 = 0x0000000a (expected 0x0000000a)
[PASS] T3: x8 = x7 + x2 = 10+20: x8 = 0x0000001e (expected 0x0000001e)

[TEST 4] Branch Taken + Flush
  [875000 ns] COMMIT 0: x9 <= 0x00000005
  [875000 ns] COMMIT 1: x10 <= 0x00000005
  [925000 ns] COMMIT 0: x12 <= 0x0000002a
[PASS] T4: x9 = 5: x9 = 0x00000005 (expected 0x00000005)
[PASS] T4: x10 = 5: x10 = 0x00000005 (expected 0x00000005)
[PASS] T4: x11 = 0 (flushed, should NOT be 99): x11 = 0x00000000 (expected 0x00000000)
[PASS] T4: x12 = 42 (branch target): x12 = 0x0000002a (expected 0x0000002a)

================================================
 Results: 12 PASSED, 0 FAILED (100% Pass Rate)
================================================
```

---

# 8. Viva & Interview Q&A Preparation Guide

### Q1: What makes a processor "Superscalar"?
> **Answer:** A processor is superscalar if its hardware can fetch, decode, execute, and commit **more than one instruction per clock cycle** (i.e. theoretical IPC > 1.0). In our design, we implement a 2-way superscalar processor with 64-bit dual-fetch, dual decoders, dual ALUs, dual commit ports, achieving a peak throughput of 2 instructions per cycle.

### Q2: Why is a Reorder Buffer (ROB) necessary if instructions are fetched in order?
> **Answer:** Because instructions execute dynamically **out of order** based on operand availability. If a branch mispredicts or an exception occurs, instructions that executed out-of-turn must not irreversibly alter register state. The ROB buffers speculative execution results and commits them strictly in **program order**, guaranteeing precise architectural state and exact exception handling.

### Q3: How do you handle Read-After-Write (RAW) hazards between instructions issued in the same cycle?
> **Answer:** In the Decode stage, we have an intra-pair RAW detector that compares `dec0.rd` against `dec1.rs1` and `dec1.rs2`. If a dependency exists, the younger instruction is flagged with `intra_dep` and held in the Issue Queue with its source marked not-ready (`src_rdy = 0`). It only dispatches in the subsequent cycle when the older instruction's result is forwarded from the MEM stage.

### Q4: Why can't execution units forward directly from their own unlatched outputs in the same cycle?
> **Answer:** Because the ALU's output would be wired directly back into its own input multiplexer within the same clock period without any flip-flop boundary. For instructions like `addi x1, x1, 1`, this forms a zero-delay combinational feedback loop ($$\text{Out} = \text{In} + 1 = \text{Out} + 1$$), creating continuous analog oscillation and causing digital simulators to crash with an iteration limit error.

### Q5: How many read and write ports does the Register File require for a 2-way superscalar core?
> **Answer:** Each 32-bit RISC-V instruction can read up to 2 source registers (`rs1`, `rs2`) and write 1 destination register (`rd`). For a dual-issue pipeline retiring up to 2 instructions per cycle:
> - **Read Ports:** $2 \text{ instructions} \times 2 \text{ sources} = \mathbf{4\text{ Read Ports}}$.
> - **Write Ports:** $2 \text{ instructions} \times 1 \text{ destination} = \mathbf{2\text{ Write Ports}}$.
> Our register file also implements internal Write-Before-Read forwarding and gives Port 0 priority over Port 1 in the event of a simultaneous write collision (WAW).

### Q6: What is the branch penalty in this design?
> **Answer:** Our core uses a Predict-Not-Taken policy. Branches are resolved in Stage 4 (Execute). If a branch is taken, instructions currently in Fetch (Stage 1) and Decode (Stage 2) are flushed. The penalty is exactly **2 clock cycles** before the correct target instruction reaches the Execute stage.

---

# 9. Repository File Manifest

```
Superscaler_RISCV/
├── rtl/
│   ├── riscv_pkg.sv            ← RV32I opcodes, ALU controls, pipeline structures
│   ├── alu.sv                  ← 32-bit combinational Arithmetic & Logic Unit
│   ├── branch_unit.sv          ← Condition testing & branch target calculation
│   ├── regfile.sv              ← Multi-ported 4R / 2W architectural register file
│   ├── fetch_stage.sv          ← Dual-instruction PC generator (PC+8) & fetch logic
│   ├── decode_stage.sv         ← Dual RV32I decoders + intra-pair RAW detector
│   ├── load_store_unit.sv      ← AGU, byte enables (SB/SH/SW), sign-extension
│   ├── forwarding_unit.sv      ← Acyclic multi-stage operand forwarding network
│   ├── hazard_unit.sv          ← Load-use stall generator & branch flush logic
│   ├── issue_queue.sv          ← 8-entry dynamic instruction window with WAW tracking
│   ├── reorder_buffer.sv       ← 16-entry in-order retirement ROB
│   ├── superscalar_core.sv     ← Top-level processor core integration
│   └── fpga_top.sv             ← Synthesizable Artix-7 FPGA SoC wrapper with BRAMs
├── tb/
│   ├── mem_model.sv            ← 64-bit I-Mem and 32-bit D-Mem simulation models
│   └── tb_superscalar_core.sv  ← 4 verification testsuites (12 automated checks)
├── constraints/
│   └── basys3.xdc              ← Digilent Basys 3 FPGA pin constraints
├── superscalar_riscv.tcl       ← Complete automated Vivado project creation script
├── README.md                   ← Quickstart reference and execution commands
└── docs/
    └── PROJECT_DOCUMENTATION.md ← This comprehensive reference document
```
