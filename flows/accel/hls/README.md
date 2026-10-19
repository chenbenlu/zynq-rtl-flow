# HLS kernels

One directory per kernel: C++ source, C testbench and an `hls.cfg`.
`make hls KERNEL=<name>` compiles `hls/<name>/` into a `.xo`.

They exist to give an HLS-derived comparison point for the embedded flow's
hand-written RTL — not a route to synthesising that RTL. The two flows stay
separate (see [CONTEXT.md](../../../CONTEXT.md)).

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

Leave `part` out: it is a general `v++` option, not an `[hls]` one, and `hls.sh`
passes it from `BOARD`, so one config serves every board.
