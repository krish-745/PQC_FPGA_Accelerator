# Load a bitstream into the FPGA over JTAG (the board's USB PROG port):
#   vivado -mode batch -source scripts/program.tcl -tclargs <file.bit>
set bit [lindex $argv 0]
open_hw_manager
connect_hw_server
set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} { puts "PROGRAM FAILED: no JTAG target (board not connected or not powered)"; exit 1 }
open_hw_target [lindex $targets 0]
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAM DONE $bit"
