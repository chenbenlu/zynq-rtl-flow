# =============================================================================
# Out-of-context synthesis — a measurement, not a step towards a bitstream.
#
# Synthesises one module alone, with no surrounding design and no I/O buffers,
# to answer "what does this module cost and how fast can it run". The clock
# constraint is deliberately aggressive: the reported slack is how the achieved
# Fmax is derived, so a constraint that is comfortably met tells us nothing.
#
# Driven by flows/embedded/synth.sh, which supplies every value below.
# =============================================================================

set rtl_top     $::env(RTL_TOP)
set part        $::env(BOARD_PART)
set out_dir     $::env(OUT_DIR)
set clk_period  $::env(CLK_PERIOD)
set clk_port    $::env(CLK_PORT)
set sources     [split $::env(RTL_SOURCES) " "]

file mkdir $out_dir

foreach src $sources {
  if {$src eq ""} { continue }
  read_verilog -sv $src
}

synth_design -top $rtl_top -part $part -mode out_of_context

create_clock -name ooc_clk -period $clk_period [get_ports $clk_port]

# Nothing drives or loads the module in OOC, so every path to or from a port is
# unconstrained and would otherwise be reported as a false violation. Budget
# them at 20% of the period, which is conventional and keeps the report focused
# on the register-to-register paths we actually care about.
set io_budget [expr {$clk_period * 0.2}]
set_input_delay  -clock ooc_clk $io_budget [filter [all_inputs] "NAME != $clk_port"]
set_output_delay -clock ooc_clk $io_budget [all_outputs]

opt_design

write_checkpoint -force $out_dir/post_synth.dcp
report_utilization      -file $out_dir/utilization.rpt
report_timing_summary   -file $out_dir/timing_summary.rpt
report_timing -max_paths 10 -sort_by group -file $out_dir/timing_paths.rpt

# The number the baseline exists to produce. WNS is against clk_period, so the
# achieved period is the constraint minus the slack.
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set achieved [expr {$clk_period - $wns}]
set fmax [expr {1000.0 / $achieved}]

set fh [open $out_dir/baseline.txt w]
puts $fh "top         $rtl_top"
puts $fh "part        $part"
puts $fh "constraint  $clk_period ns"
puts $fh "wns         $wns ns"
puts $fh "achieved    $achieved ns"
puts $fh "fmax        [format %.1f $fmax] MHz"
close $fh

puts ">> OOC baseline: Fmax [format %.1f $fmax] MHz (WNS $wns ns @ $clk_period ns)"
puts ">> Reports in $out_dir"
