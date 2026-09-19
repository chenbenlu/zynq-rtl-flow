# KV260 (xck26, -2LV) — target PL clock 200 MHz (5.0 ns).
#
# The PL clock is created by the Zynq MPSoC IP from the frequency the block
# design asks for (flows/common/boards.sh, BOARD_PL_CLK_MHZ), so this file does
# not create it. What it adds is the margin the automatic constraint cannot
# know about: clock-tree and jitter uncertainty for a clock that leaves the PS,
# crosses the PL and comes back.
#
# `-quiet` is the whole guard. Vivado reads an XDC in a restricted Tcl mode
# with no `if`, so wrapping this in one skipped the constraint itself and cost
# 0.100 ns of margin every design here was judged against. An empty object list
# is not an error — it is a CRITICAL WARNING and the run continues, which is
# the failure mode worth having: loud, and on the side that does not silently
# flatter the result.
set_clock_uncertainty -setup 0.100 [get_clocks -quiet clk_pl_0]
