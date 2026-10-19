# ============================================================
# superscalar_riscv.tcl
# Vivado project creation and simulation script for the
# Dual-Issue Superscalar RISC-V Core.
#
# Usage (Vivado Tcl Console):
#   cd d:/Projects/Superscaler_RISCV
#   source superscalar_riscv.tcl
# ============================================================

set project_name "superscalar_riscv"
set project_dir  [file normalize [file dirname [info script]]]

# Close existing project if open
catch {close_project}

# Create Project (target Artix-7 xc7a35t)
create_project $project_name "$project_dir/$project_name" -part xc7a35tcpg236-1 -force

# In Vivado, target_language only accepts 'Verilog' or 'VHDL'
# Individual source files are designated as 'SystemVerilog'
set_property target_language Verilog [current_project]

# --- Add RTL Source Files ---
set rtl_files [list \
    "$project_dir/rtl/riscv_pkg.sv"        \
    "$project_dir/rtl/alu.sv"              \
    "$project_dir/rtl/branch_unit.sv"      \
    "$project_dir/rtl/regfile.sv"          \
    "$project_dir/rtl/fetch_stage.sv"      \
    "$project_dir/rtl/decode_stage.sv"     \
    "$project_dir/rtl/load_store_unit.sv"  \
    "$project_dir/rtl/forwarding_unit.sv"  \
    "$project_dir/rtl/hazard_unit.sv"      \
    "$project_dir/rtl/issue_queue.sv"      \
    "$project_dir/rtl/reorder_buffer.sv"   \
    "$project_dir/rtl/superscalar_core.sv" \
    "$project_dir/rtl/fpga_top.sv"         \
]

add_files -norecurse $rtl_files
set_property file_type SystemVerilog [get_files -of_objects [current_fileset]]

# --- Add Constraints ---
if {[file exists "$project_dir/constraints/basys3.xdc"]} {
    add_files -fileset constrs_1 -norecurse "$project_dir/constraints/basys3.xdc"
}

# --- Add Simulation / Testbench Files ---
set tb_files [list \
    "$project_dir/tb/mem_model.sv"           \
    "$project_dir/tb/tb_superscalar_core.sv" \
]

add_files -fileset sim_1 -norecurse $tb_files
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sim_1]]

# Set package to be compiled first / global include
catch {set_property is_global_include true [get_files riscv_pkg.sv]}

# --- Set Top Modules & Update Compile Hierarchy ---
update_compile_order -fileset sources_1
set_property top superscalar_core [current_fileset]

update_compile_order -fileset sim_1
set_property top tb_superscalar_core [get_filesets sim_1]

puts ""
puts "=================================================="
puts "  Superscalar RISC-V Project Created Successfully"
puts "=================================================="
puts " Next steps:"
puts "   1. Run simulation:  launch_simulation"
puts "   2. Run testbench:   run all"
puts "   3. Run synthesis:   launch_runs synth_1"
puts "=================================================="
