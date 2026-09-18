#!/usr/bin/env python3
"""Run tiles through an accelerator on the board and check them against its golden model.

Run as root on the ZCU104 with the transport and that accelerator's register
layer loaded:

    sudo python3 run-tile.py [sparse_cnn | relu]

With no argument it uses whichever character device is there. The expected
results come from tb/model/ — the same definitions the cocotb testbenches use,
so a disagreement here is a disagreement between hardware and simulation rather
than between two ideas of what the accelerator computes.

The DMA's interrupt count is reported alongside, because a tile that completes
without it having moved would mean the driver polled its way to the right answer
and the interrupt this design carries is still unproven. An accelerator with a
return path takes two lines rather than one, and both are summed.
"""

import os
import pathlib
import struct
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tb" / "model"))
import relu_model  # noqa: E402
import sparse_mac_model  # noqa: E402

IRQ_NAME = "xilinx-dma-controller"
RELU_SLOPE = "/sys/class/misc/relu/device/slope"

# Length, zero fraction, seed. The first is dense enough that SKIP should stay 0
# and the last sparse enough that most pairs are skipped, so a SKIP that is
# silently stuck at either end cannot pass.
SPARSE_TILES = [
    (16, 0.0, 1),
    (64, 0.25, 2),
    (256, 0.5, 3),
    (1024, 0.9, 4),
    (4096, 0.5, 5),
]

# Length, negative fraction, slope, seed. The slope is swept across its range
# because it is the one writable field either accelerator has: 0 makes a plain
# ReLU, 25 is the reset value, 255 is very nearly the identity. A SLOPE write
# that never reached the data path would agree with the model only at 25.
RELU_TILES = [
    (16, 1.0, 0, 1),
    (64, 0.5, 25, 2),
    (256, 0.5, 255, 3),
    (1024, 0.75, 1, 4),
    (4096, 0.5, 128, 5),
]


def irq_count():
    """Interrupts taken on the accelerator's DMA, summed over lines and CPUs.

    One line per connected channel, so an accelerator with a return path has
    two. Summing them keeps the check the same for both shapes.
    """
    total = None
    with open("/proc/interrupts") as fh:
        for line in fh:
            if IRQ_NAME in line:
                total = (total or 0) + sum(
                    int(f) for f in line.split()[1:] if f.isdigit()
                )
    return total


def run_sparse_cnn(fd):
    header = ("beats", "sparsity", "acc", "expected", "skip", "expected")
    print("%6s %9s %12s %12s %7s %9s" % header)

    matched = 0
    for n, sparsity, seed in SPARSE_TILES:
        weights, acts = sparse_mac_model.gen_pairs(n, sparsity, seed)
        beats = b"".join(
            struct.pack("<H", ((int(a) & 0xFF) << 8) | (int(w) & 0xFF))
            for w, a in zip(weights, acts)
        )
        os.write(fd, beats)
        acc, skip = struct.unpack("<iI", os.read(fd, 8))

        want_acc, want_skip = sparse_mac_model.golden(weights, acts)
        ok = acc == want_acc and skip == want_skip
        matched += ok
        print(
            "%6d %9.2f %12d %12d %7d %9d  %s"
            % (n, sparsity, acc, want_acc, skip, want_skip, "ok" if ok else "MISMATCH")
        )
    return matched, len(SPARSE_TILES)


def run_relu(fd):
    print("%6s %9s %6s %s" % ("beats", "negative", "slope", "result"))

    matched = 0
    for n, negative_ratio, slope, seed in RELU_TILES:
        with open(RELU_SLOPE, "w") as fh:
            fh.write("%d\n" % slope)

        tile = relu_model.gen_activations(
            n, negative_ratio=negative_ratio, rng=np.random.default_rng(seed)
        )
        os.write(fd, np.asarray(tile, dtype=np.int8).tobytes())
        got = np.frombuffer(os.read(fd, n), dtype=np.int8).astype(np.int64)

        want = relu_model.golden(tile, slope)
        wrong = int(np.count_nonzero(got != want))
        matched += not wrong
        print(
            "%6d %9.2f %6d  %s"
            % (
                n,
                negative_ratio,
                slope,
                "ok" if not wrong else "MISMATCH in %d of %d beats" % (wrong, n),
            )
        )
    return matched, len(RELU_TILES)


RUNNERS = {"sparse_cnn": run_sparse_cnn, "relu": run_relu}


def main(argv):
    if len(argv) > 1:
        name = argv[1]
        if name not in RUNNERS:
            sys.exit("no checks for %r — one of: %s" % (name, ", ".join(RUNNERS)))
    else:
        present = [n for n in RUNNERS if os.path.exists("/dev/" + n)]
        if len(present) != 1:
            sys.exit(
                "name the accelerator to run: %s (found %s)"
                % (", ".join(RUNNERS), ", ".join(present) or "none")
            )
        name = present[0]

    before = irq_count()
    if before is None:
        sys.exit("no %s line in /proc/interrupts — is the overlay loaded?" % IRQ_NAME)

    print("-- %s" % name)
    fd = os.open("/dev/" + name, os.O_RDWR)
    try:
        matched, total = RUNNERS[name](fd)
    finally:
        os.close(fd)

    taken = irq_count() - before
    print("\n%d of %d tiles matched the golden model" % (matched, total))
    print("%s took %d interrupts over those tiles" % (IRQ_NAME, taken))
    if not taken:
        print("the tiles completed without the interrupt firing — it is still unproven")

    return 0 if matched == total and taken else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
