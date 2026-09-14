# HLS kernels

One directory per kernel, holding its C++ source, its C testbench and an
`hls.cfg`. `make hls KERNEL=<name>` compiles `hls/<name>/` into a `.xo`.

These exist to produce an HLS-derived comparison point for the hand-written RTL
of the embedded flow. They are not a route to synthesising the RTL — the two
flows stay separate (see [CONTEXT.md](../../../CONTEXT.md)).

## hls.cfg

2026.1 has no `vitis_hls` binary: HLS is a mode of `v++`, configured by file
rather than by Tcl script. A minimal config:

```
[hls]
syn.file=sparse_conv.cpp
syn.top=sparse_conv
tb.file=sparse_conv_tb.cpp
syn.output.format=xo
clock=3.0
clock_uncertainty=12%
```

Leave `part` out. It is a general `v++` option rather than an `[hls]` one, and
`hls.sh` passes it from `BOARD` — so one config serves every target board.
