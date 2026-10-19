# Vitis platforms

One directory per board: the `.xpfm` and its supporting files. `make xclbin`
links kernels against the platform here for the selected board.

A platform packages the hardware design exported from Vivado (`.xsa`) with the
board's runtime. For KV260 it is expected to build on the AMD-provided base, not
be written from scratch.
