# Vivado batch build: synthesis, implementation (place + route), reports and (for board targets) the bitstream.
#   vivado -mode batch -source scripts/build.tcl -tclargs <target> <out_dir> [period=10.0] [P=1] [DIL_SPECIAL=0]
# Targets:
#   echo  top_uart_echo on the Nexys 4 DDR (pins from constraints/nexys4ddr.xdc), bitstream
#   sys   full system top.v on the board (UART + NTT core + Keccak), bitstream
#   mul   standalone multiplier, out of context, registered at its ports (bench_mod_mul.v)
#   core  standalone NTT core, out of context, registered at its ports (bench_ntt_core.v)
# Out-of-context targets get one clock constraint on port clk (period=...); their ports are
# registered inside the bench wrapper, so every timed path is register to register.
# Reports in <out_dir>: synth_util.rpt (synthesis estimate), route_util.rpt, route_util_hier.rpt,
# route_timing.rpt (post-route), summary.txt (key = value lines read by scripts/flow.py).

set target [lindex $argv 0]
set out    [file normalize [lindex $argv 1]]
set opts   [dict create period 10.0 P 1 DIL_SPECIAL 0 FIXED_MODE 2]
foreach kv [lrange $argv 2 end] {
    set i [string first = $kv]
    dict set opts [string range $kv 0 [expr {$i - 1}]] [string range $kv [expr {$i + 1}] end]
}
set root [file normalize [file join [file dirname [info script]] ..]]
set part xc7a100tcsg324-1
file mkdir $out

set core_srcs {mod_mul butterfly twiddle_rom ntt_core}
switch $target {
    echo { set top top_uart_echo; set srcs {uart_rx uart_tx fifo_sync reset_sync top_uart_echo}; set ooc 0; set gens {} }
    sys  { set top top; set srcs [concat $core_srcs {keccak_f1600 keccak_core uart_rx uart_tx reset_sync cmd_ctrl top}]
           set ooc 0; set gens [list P=[dict get $opts P] DIL_SPECIAL=[dict get $opts DIL_SPECIAL]] }
    mul  { set top bench_mod_mul; set srcs {mod_mul bench_mod_mul}; set ooc 1
           set gens [list DIL_SPECIAL=[dict get $opts DIL_SPECIAL] FIXED_MODE=[dict get $opts FIXED_MODE]] }
    core { set top bench_ntt_core; set srcs [concat $core_srcs {bench_ntt_core}]; set ooc 1
           set gens [list P=[dict get $opts P] DIL_SPECIAL=[dict get $opts DIL_SPECIAL]] }
    default { puts "unknown target $target"; exit 1 }
}

foreach s $srcs { read_verilog [file join $root rtl $s.v] }
set gargs {}
foreach g $gens { lappend gargs -generic $g }
if {$ooc} {
    # the clock constraint is read before synthesis, so synthesis optimizes for the same period
    set fx [open [file join $out ooc_clock.xdc] w]
    puts $fx "create_clock -name clk -period [dict get $opts period] \[get_ports clk\]"
    close $fx
    read_xdc [file join $out ooc_clock.xdc]
    synth_design -top $top -part $part -mode out_of_context {*}$gargs
} else {
    read_xdc [file join $root constraints nexys4ddr.xdc]
    synth_design -top $top -part $part {*}$gargs
}
report_utilization -file [file join $out synth_util.rpt]

opt_design
# optional placement directive (directive=...), e.g. to retry a marginal timing point with another placement
if {[dict exists $opts directive]} { place_design -directive [dict get $opts directive] } else { place_design }
phys_opt_design
route_design
report_utilization -file [file join $out route_util.rpt]
report_utilization -hierarchical -file [file join $out route_util_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out route_timing.rpt]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set f [open [file join $out summary.txt] w]
puts $f "target = $target"
puts $f "top = $top"
puts $f "part = $part"
puts $f "vivado = [version -short]"
dict for {k v} $opts { puts $f "$k = $v" }
if {!$ooc} { puts $f "period = 10.0 (constraints/nexys4ddr.xdc)" }
puts $f "wns_ns = $wns"
puts $f "whs_ns = $whs"
close $f

if {!$ooc} {
    write_bitstream -force [file join $out $target.bit]
}
puts "BUILD DONE $target wns=$wns whs=$whs"
