#!/usr/bin/env python3
"""Run tiles through the accelerator on the board and check them against the golden model.

Run as root on the ZCU104 with the driver loaded. The expected results come from
tb/model/sparse_mac_model.py — the same definition the cocotb testbenches use, so
a disagreement here is a disagreement between hardware and simulation rather than
between two ideas of what the accelerator computes.

The DMA's interrupt count is reported alongside, because a tile that completes
without it having moved would mean the driver polled its way to the right answer
and the interrupt this design carries is still unproven.
"""

import os
import pathlib
import struct
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tb" / "model"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sparse_mac_model import gen_pairs, golden  # noqa: E402

DEV = "/dev/sparse_cnn"
IRQ_NAME = "xilinx-dma-controller"

# Length, zero fraction, seed. The first is dense enough that SKIP should stay 0
# and the last sparse enough that most pairs are skipped, so a SKIP that is
# silently stuck at either end cannot pass.
TILES = [
    (16, 0.0, 1),
    (64, 0.25, 2),
    (256, 0.5, 3),
    (1024, 0.9, 4),
    (4096, 0.5, 5),
]


def irq_count():
    """Interrupts taken on the accelerator's DMA, summed over CPUs."""
    with open("/proc/interrupts") as fh:
        for line in fh:
            if IRQ_NAME in line:
                return sum(int(f) for f in line.split()[1:] if f.isdigit())
    return None


def run_tile(fd, weights, acts):
    beats = b"".join(
        struct.pack("<H", ((int(a) & 0xFF) << 8) | (int(w) & 0xFF))
        for w, a in zip(weights, acts)
    )
    os.write(fd, beats)
    return struct.unpack("<iI", os.read(fd, 8))


def main():
    before = irq_count()
    if before is None:
        sys.exit("no %s line in /proc/interrupts — is the overlay loaded?" % IRQ_NAME)

    fd = os.open(DEV, os.O_RDWR)
    matched = 0
    header = ("beats", "sparsity", "acc", "expected", "skip", "expected")
    print("%6s %9s %12s %12s %7s %9s" % header)
    try:
        for n, sparsity, seed in TILES:
            weights, acts = gen_pairs(n, sparsity, seed)
            acc, skip = run_tile(fd, weights, acts)
            want_acc, want_skip = golden(weights, acts)
            ok = acc == want_acc and skip == want_skip
            matched += ok
            print(
                "%6d %9.2f %12d %12d %7d %9d  %s"
                % (n, sparsity, acc, want_acc, skip, want_skip, "ok" if ok else "MISMATCH")
            )
    finally:
        os.close(fd)

    taken = irq_count() - before
    print("\n%d of %d tiles matched the golden model" % (matched, len(TILES)))
    print("%s took %d interrupts over those tiles" % (IRQ_NAME, taken))
    if not taken:
        print("the tiles completed without the interrupt firing — it is still unproven")

    return 0 if matched == len(TILES) and taken else 1


if __name__ == "__main__":
    sys.exit(main())
