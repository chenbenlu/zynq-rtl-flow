# HLS kernels

One directory per kernel, holding its C++ source and its C testbench. `make hls
KERNEL=<name>` compiles `hls/<name>/` into a `.xo`.

These exist to produce an HLS-derived comparison point for the hand-written RTL
of the embedded flow. They are not a route to synthesising the RTL — the two
flows stay separate (see [CONTEXT.md](../../../CONTEXT.md)).
