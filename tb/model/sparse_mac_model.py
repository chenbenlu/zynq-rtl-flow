"""The golden model, shared by every seam that verifies sparse MAC behaviour.

There is one definition of what the accelerator computes. Both the bare PE
testbench and the AXI wrapper testbench import it from here; if they ever
disagree that is a finding, not a maintenance task.
"""

from __future__ import annotations

import numpy as np

# Must match sparse_cnn_pkg (the RTL is elaborated with these defaults).
DATA_W = 8
ACC_W = 32
SKIP_W = 16

DATA_MIN = -(1 << (DATA_W - 1))
DATA_MAX = (1 << (DATA_W - 1)) - 1
DATA_MASK = (1 << DATA_W) - 1


def golden(weights, acts) -> tuple[int, int]:
    """Expected (accumulator, zero-skip count) for one tile of operand pairs."""
    acc = 0
    skip = 0
    for w, a in zip(weights, acts):
        w, a = int(w), int(a)
        if w == 0 or a == 0:
            skip += 1
        else:
            acc += w * a
    return acc, skip


def gen_pairs(n: int, sparsity: float, seed: int):
    """Random signed operands with ~`sparsity` fraction of zeros injected."""
    rng = np.random.default_rng(seed)
    w = rng.integers(DATA_MIN, DATA_MAX + 1, size=n)
    a = rng.integers(DATA_MIN, DATA_MAX + 1, size=n)
    if sparsity > 0:
        w[rng.random(n) < sparsity] = 0
        a[rng.random(n) < sparsity] = 0
    return w, a


def to_signed(raw: int, width: int) -> int:
    raw &= (1 << width) - 1
    if raw & (1 << (width - 1)):
        raw -= 1 << width
    return raw
