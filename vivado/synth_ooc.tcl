# Synthesize, place and route one module on its own (out of context) at 100 MHz, to check resources and timing early.
# From the repo root:  vivado -mode batch -source vivado/synth_ooc.tcl -tclargs mod_mul
# Reports go to build/vivado/<module>/.

set top  [lindex $argv 0]
set part xc7a100tcsg324-1
set out  build/vivado/$top
file mkdir $out

read_verilog [glob rtl/*.v]
synth_design -top $top -part $part -mode out_of_context -include_dirs rtl

if {[llength [get_ports -quiet clk]]} {
    create_clock -name clk -period 10.0 [get_ports clk]
}

opt_design
place_design
route_design

report_utilization    -file $out/utilization.txt
report_timing_summary -file $out/timing.txt
report_utilization -hierarchical -file $out/utilization_hier.txt
