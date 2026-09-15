# KV260 (xck26, -2LV) — target PL clock 200 MHz (5.0 ns).
#
# The PL clock is created by the Zynq MPSoC IP from the frequency the block
# design asks for (flows/common/boards.sh, BOARD_PL_CLK_MHZ), so this file does
# not create it. What it adds is the margin the automatic constraint cannot
# know about: clock-tree and jitter uncertainty for a clock that leaves the PS,
# crosses the PL and comes back.
set pl_clk [get_clocks -quiet clk_pl_0]
if {[llength $pl_clk]} {
  set_clock_uncertainty -setup 0.100 $pl_clk
}
