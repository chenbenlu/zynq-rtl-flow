# ZCU104 (xczu7ev, -2) — target PL clock 250 MHz (4.0 ns).
#
# The faster speed grade carries a higher target than KV260; see
# flows/common/boards.sh for where the two numbers come from. As on KV260 the
# PL clock itself comes from the Zynq MPSoC IP, and this file only adds the
# system margin.
#
# `-quiet` is the whole guard, for the reason spelled out in the KV260 file:
# an `if` here is not read as Tcl, and a missing clock is a CRITICAL WARNING
# rather than an error.
set_clock_uncertainty -setup 0.100 [get_clocks -quiet clk_pl_0]
