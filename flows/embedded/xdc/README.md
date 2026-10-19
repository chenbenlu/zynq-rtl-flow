# Constraints

One directory per board (`kv260/`, `zcu104/`). `make impl` reads every `.xdc` in
the directory for the selected `BOARD`.

The system design has no external PL pins — the accelerator reaches the outside
world only through the PS — so these files carry timing margin, not pin
assignments. The Zynq MPSoC IP creates the PL clock at the frequency
`flows/common/boards.sh` asks for; the XDC adds the system uncertainty that
automatic constraint does not know about.

`make synth` (out-of-context) does **not** read these. It constrains its own
clock in `ooc_synth.tcl`, because it measures a module in isolation rather than
building for a board.
