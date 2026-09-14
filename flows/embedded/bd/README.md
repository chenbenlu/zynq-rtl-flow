# Block design

`system.tcl` — the block design `make impl` builds: the Zynq PS, the AXI
interconnect, and the accelerator attached to it. Written as a Tcl script rather
than a checked-in `.bd`, so the design is reviewable and rebuildable.

It does not exist yet: the accelerator has no AXI interface to attach. `make
impl` reports precisely that until it does.
