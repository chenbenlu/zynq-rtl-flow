# =============================================================================
# Export the hardware handoff for the PS-side boot flow.
# Driven by flows/embedded/xsa.sh.
# =============================================================================

set out_dir $::env(OUT_DIR)
set board   $::env(BOARD)
set xsa     $out_dir/$board.xsa

open_project $out_dir/prj/impl_prj.xpr
open_run impl_1

# No -include_bit. That switch takes the bitstream from the implementation run,
# and this flow writes it from the routed checkpoint instead (bitstream.tcl), so
# the run has none and the export aborts with "Unable to get BIT file from
# implementation run". The bitstream is a separate artefact beside the XSA and
# bootgen is handed both; nothing downstream needs it packaged inside.
write_hw_platform -fixed -force $xsa

# The export can succeed and still produce a platform the software tools reject.
validate_hw_platform $xsa

puts ">> XSA: $xsa"
exit
