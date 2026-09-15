# Constraints

One directory per board (`kv260/`, `zcu104/`), holding the timing and pin
constraints for that board's system design. `make impl` reads every `.xdc` in
the directory for the selected `BOARD`.

The system design has no external PL pins — the accelerator reaches the outside
world only through the PS — so these files carry timing margin rather than pin
assignments. The PL clock is created by the Zynq MPSoC IP at the frequency
`flows/common/boards.sh` asks for; the XDC adds the system uncertainty that the
automatic constraint does not know about.

Out-of-context synthesis (`make synth`) does **not** read these: it constrains
its own clock in `ooc_synth.tcl`, because it is measuring a module in isolation
rather than building something for a board.
