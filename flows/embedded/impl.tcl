# =============================================================================
# Place & route the system design, and record what it cost.
#
# Unlike ooc_synth.tcl this is not a measurement of one module in isolation: it
# builds the whole design — PS, interconnect, DMA and the AXI-wrapped
# accelerator — and reports resources and timing for something that could be put
# on a board. Driven by flows/embedded/impl.sh, which supplies every value below.
# =============================================================================

set out_dir    $::env(OUT_DIR)
set part       $::env(BOARD_PART)
set board_file $::env(BOARD_FILE)
set board      $::env(BOARD)
set xdc_dir    $::env(XDC_DIR)
set system_tcl $::env(SYSTEM_TCL)
set pl_clk_mhz $::env(PL_CLK_MHZ)
set sources    [split $::env(RTL_SOURCE_LIST) " "]
set jobs       $::env(IMPL_JOBS)

file mkdir $out_dir

# A block design needs a project on disk; the out-of-context flow's in-memory
# project cannot hold one.
create_project -force impl_prj $out_dir/prj -part $part
if {$board_file ne ""} {
  set_property board_part $board_file [current_project]
}

foreach src $sources {
  if {$src eq ""} { continue }
  add_files -norecurse -fileset sources_1 $src
}
set_property file_type SystemVerilog [get_files *.sv]

source $system_tcl

set bd_file [get_files system.bd]
make_wrapper -files $bd_file -top
add_files -norecurse [file rootname $bd_file]/hdl/system_wrapper.v
set_property top system_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse [glob $xdc_dir/*.xdc]

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
  error "synthesis failed — see $out_dir/prj/impl_prj.runs/synth_1/"
}

launch_runs impl_1 -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
  error "implementation failed — see $out_dir/prj/impl_prj.runs/impl_1/"
}

open_run impl_1
write_checkpoint -force $out_dir/post_route.dcp

report_utilization              -file $out_dir/utilization_impl.rpt
# Hierarchical, because the question this build answers is what the AXI
# interface costs on top of the PE's 100 LUTs — which is a per-instance number,
# not a design total.
report_utilization -hierarchical -file $out_dir/utilization_hier.rpt
report_timing_summary           -file $out_dir/timing_summary_impl.rpt
report_timing -max_paths 10 -sort_by group -file $out_dir/timing_paths_impl.rpt

# The claim "it met timing" is about a number: the target the board asked for.
# The design-wide worst path belongs to whichever clock happens to be tightest,
# including PS-side clocks the accelerator does not run on, so the slack is
# taken from the PL clock's own path group.
set target_period [expr {1000.0 / $pl_clk_mhz}]
set pl_clk [get_clocks -quiet clk_pl_0]
if {[llength $pl_clk]} {
  set clk_label "clk_pl_0"
  set paths [get_timing_paths -delay_type max -max_paths 1 -group $pl_clk]
} else {
  set clk_label "design-wide (PL clock not found by name)"
  set paths [get_timing_paths -delay_type max -max_paths 1]
}
set wns [get_property SLACK $paths]

set fh [open $out_dir/impl_summary.txt w]
puts $fh "board         $board"
puts $fh "part          $part"
puts $fh "target        $pl_clk_mhz MHz ([format %.3f $target_period] ns)"
puts $fh "clock         $clk_label"
puts $fh "wns           $wns ns"
puts $fh "achieved      [format %.1f [expr {1000.0 / ($target_period - $wns)}]] MHz"
puts $fh "timing met    [expr {$wns >= 0 ? "yes" : "no"}]"
puts $fh ""
puts $fh "Whole-design utilization is in utilization_impl.rpt; the accelerator's"
puts $fh "own share — the number to compare against the PE's 100-LUT OOC"
puts $fh "baseline — is the sparse_cnn_axi row of utilization_hier.rpt."
close $fh

puts ""
puts [read [open $out_dir/impl_summary.txt r]]
if {$wns < 0} {
  puts ">> WARNING: timing NOT met at $pl_clk_mhz MHz (WNS $wns ns)"
  puts ">>   lower BOARD_PL_CLK_MHZ in flows/common/boards.sh, or fix the design"
}
puts ">> Reports in $out_dir"
