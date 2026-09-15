# Vitis platforms

One directory per board, holding the `.xpfm` and its supporting files. `make
xclbin` links kernels against the platform found here for the selected board.

A platform packages the hardware design exported from Vivado (`.xsa`) together
with the board's runtime. For KV260 this is expected to build on the AMD-provided
base rather than being written from scratch.
