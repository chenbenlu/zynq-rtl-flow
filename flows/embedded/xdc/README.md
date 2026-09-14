# Constraints

One directory per board (`kv260/`, `zcu104/`), holding the timing and pin
constraints for that board's system design. `make impl` requires them.

Out-of-context synthesis (`make synth`) does **not** read these: it constrains
its own clock in `ooc_synth.tcl`, because it is measuring a module in isolation
rather than building something for a board.
