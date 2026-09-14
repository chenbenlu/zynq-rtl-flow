# =============================================================================
# Vitis HLS: compile one kernel to a .xo for the acceleration flow.
# Driven by flows/accel/hls.sh, which supplies every value below.
# =============================================================================

set kernel   $::env(KERNEL)
set part     $::env(BOARD_PART)
set src_dir  $::env(SRC_DIR)
set out_dir  $::env(OUT_DIR)
set period   [expr {[info exists ::env(CLK_PERIOD)] ? $::env(CLK_PERIOD) : 3.0}]

open_project -reset $out_dir/hls_project
set_top $kernel

foreach src [glob -nocomplain $src_dir/*.cpp $src_dir/*.cc] {
  # Testbenches live alongside the kernel; they are C-sim inputs, not synthesis
  # inputs, and adding them to the design would fail synthesis.
  if {[string match "*_tb.*" $src]} {
    add_files -tb $src
  } else {
    add_files $src
  }
}

open_solution -reset "hw" -flow_target vitis
set_part $part
create_clock -period $period -name default

csynth_design
export_design -format xo -output $out_dir/$kernel.xo

puts ">> wrote $out_dir/$kernel.xo"
exit
