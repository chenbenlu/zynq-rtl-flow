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

# -import lets make_wrapper add the generated wrapper to the project itself.
# Handling the path by hand is what went wrong here before: since 2021.1 the
# wrapper lands in the project's .gen directory rather than beside the .bd, and
# adding the wrong file leaves the fileset without a system_wrapper to validate.
make_wrapper -files $bd_file -top -import
update_compile_order -fileset sources_1
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Setting top is a request, not a guarantee. In automatic hierarchy mode Vivado
# replaces a top it cannot validate and carries on with a CRITICAL WARNING, so
# the run happily implements the accelerator alone — no PS, no interconnect, and
# therefore no timing constraints at all, which then reports as "timing met".
# Fail here instead: implementing the wrong design must not look like success.
set actual_top [get_property top [current_fileset]]
if {$actual_top ne "system_wrapper"} {
  error "top is '$actual_top', not system_wrapper — the block design wrapper was\
 not added to the fileset, so this run would implement the accelerator without\
 the PS around it"
}

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
set wns ""
if {[llength $paths]} {
  set wns [get_property SLACK $paths]
}
# get_timing_paths can come back empty — a path group with nothing in it, or a
# clock that was not named as expected — and SLACK on nothing is an empty
# string, not zero. The run's own statistic is the reliable source; the path
# query stays because it is scoped to the PL clock, which the run-wide figure
# is not.
if {![string is double -strict $wns]} {
  set clk_label "design-wide (from impl run statistics)"
  set wns [get_property STATS.WNS [get_runs impl_1]]
}

set fh [open $out_dir/impl_summary.txt w]
puts $fh "board         $board"
puts $fh "part          $part"
puts $fh "target        $pl_clk_mhz MHz ([format %.3f $target_period] ns)"
puts $fh "clock         $clk_label"
# A design with no clocks has no slack to report, and STATS.WNS is 0 for it —
# indistinguishable from a design that met timing exactly. Check for constraints
# before believing any number.
set n_clocks [llength [get_clocks -quiet]]
if {$n_clocks == 0} {
  set wns ""
  puts $fh "clocks        none — the design has no timing constraints"
}

if {[string is double -strict $wns]} {
  puts $fh "wns           $wns ns"
  puts $fh "achieved      [format %.1f [expr {1000.0 / ($target_period - $wns)}]] MHz"
  puts $fh "timing met    [expr {$wns >= 0 ? "yes" : "no"}]"
} else {
  # Never let the summary writer discard a completed place & route: the reports
  # above are already on disk and are what matters.
  puts $fh "wns           unavailable — read timing_summary_impl.rpt"
  puts $fh "timing met    unknown"
}
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
