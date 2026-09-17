"""The golden model for the Leaky ReLU accelerator.

One definition of correct behaviour, imported by the seam that verifies the
design and never copied into it.

The negative branch truncates towards minus infinity, which is what an
arithmetic right shift does and what the RTL therefore does. ``numpy``'s
floor division agrees; Python's ``int`` division would not if it were written
with ``int(x * slope / 256)``, which rounds towards zero. The two differ for
every negative input that is not an exact multiple, so this is the whole model.
"""

from __future__ import annotations

import numpy as np

# Must match relu_pkg (the RTL is elaborated with these defaults).
DATA_W = 8
SLOPE_W = 8
SLOPE_RESET = 25
COUNT_W = 16

DATA_MIN = -(1 << (DATA_W - 1))
DATA_MAX = (1 << (DATA_W - 1)) - 1
DATA_MASK = (1 << DATA_W) - 1


def to_signed(value: int, width: int = DATA_W) -> int:
    """Interpret ``width`` raw bits as a two's-complement integer."""
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value


def golden(activations, slope: int = SLOPE_RESET) -> np.ndarray:
    """Leaky ReLU over one tile, as the RTL computes it."""
    x = np.asarray(activations, dtype=np.int64)
    scaled = (x * int(slope)) >> SLOPE_W  # numpy shifts arithmetically
    return np.where(x >= 0, x, scaled).astype(np.int64)


def gen_activations(n: int, *, negative_ratio: float = 0.5, rng=None) -> np.ndarray:
    """A tile of activations with a controlled share of negative values.

    The negative branch is the only interesting one, so a uniform generator
    would spend half its beats on a passthrough. The extremes are always
    included: DATA_MIN is where the scaled product is largest in magnitude and
    the one input whose negation does not fit the width.
    """
    rng = rng or np.random.default_rng()
    negatives = rng.integers(DATA_MIN, 0, size=n)
    positives = rng.integers(0, DATA_MAX + 1, size=n)
    pick_negative = rng.random(n) < negative_ratio
    tile = np.where(pick_negative, negatives, positives).astype(np.int64)

    for i, edge in enumerate((DATA_MIN, DATA_MAX, 0, -1)):
        if i < n:
            tile[i] = edge
    return tile
