# ZCU104 (xczu7ev, -2) — target PL clock 250 MHz (4.0 ns).
#
# The faster speed grade carries a higher target than KV260; see
# flows/common/boards.sh for where the two numbers come from. As on KV260 the
# PL clock itself comes from the Zynq MPSoC IP, and this file only adds the
# system margin.
set pl_clk [get_clocks -quiet clk_pl_0]
if {[llength $pl_clk]} {
  set_clock_uncertainty -setup 0.100 $pl_clk
}
