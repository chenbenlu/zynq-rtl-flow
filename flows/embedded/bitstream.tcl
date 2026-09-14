# =============================================================================
# Write the bitstream from a routed checkpoint.
# Driven by flows/embedded/bitstream.sh.
# =============================================================================

set out_dir $::env(OUT_DIR)
set board   $::env(BOARD)

open_checkpoint $out_dir/post_route.dcp

# -bin_file as well as the .bit: loading firmware from Linux (how KV260 is
# programmed — see docs/adr/0003-...) consumes the raw .bin, not the .bit.
write_bitstream -force -bin_file $out_dir/$board.bit

report_utilization    -file $out_dir/utilization_impl.rpt
report_timing_summary -file $out_dir/timing_summary_impl.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
if {$wns < 0} {
  puts ">> WARNING: timing NOT met, WNS $wns ns — the bitstream is not trustworthy"
} else {
  puts ">> timing met, WNS $wns ns"
}
puts ">> bitstream: $out_dir/$board.bit"
exit
