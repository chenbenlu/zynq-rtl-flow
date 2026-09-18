// SPDX-License-Identifier: GPL-2.0
/*
 * sparse_cnn — the register layer for the sparse CNN accelerator.
 *
 * One accelerator's half of a PS-side driver: the register map in
 * docs/register-map-sparse-cnn.md, which is the specification this answers to,
 * and the `compatible` string the overlay's node carries. Moving the tile is
 * accel_transport's (see accel_transport.h).
 *
 * This accelerator reduces a tile to a value and reports it in registers, so it
 * has no `m_axis` and needs no return path. read() gives eight bytes: the
 * accumulator as a signed 32-bit value, then the zero-skip count, both of the
 * last completed tile.
 */

#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>

#include "accel_transport.h"

#define REG_CTRL   0x04
#define REG_STATUS 0x08
#define REG_ACC    0x0c
#define REG_SKIP   0x10

#define ID_EXPECTED 0x53500100u

#define CTRL_START BIT(0)
#define CTRL_EN    BIT(2)

#define STATUS_BUSY BIT(0)
#define STATUS_DONE BIT(1)

/* 2 * DATA_W: bits 15:8 the activation, 7:0 the weight. */
#define BEAT_BYTES 2

/*
 * The accelerator latches its result as it absorbs the tlast beat, so DONE is
 * up by the time the DMA reports the transfer complete. This is the allowance
 * for the few cycles between the two, not a transfer's worth of patience.
 */
#define DONE_TIMEOUT_US 10000

struct sparse_cnn {
	s32 acc;
	u32 skip;
};

static int sparse_cnn_accept(struct accel_device *ac)
{
	if (readl(accel_regs(ac) + REG_STATUS) & STATUS_BUSY)
		return -EBUSY;
	return 0;
}

static void sparse_cnn_start(struct accel_device *ac)
{
	/*
	 * One write, and EN has to be in it: EN is a level rather than a pulse,
	 * so writing START alone would disable the accelerator in the same
	 * cycle it was told to begin.
	 */
	writel(CTRL_EN | CTRL_START, accel_regs(ac) + REG_CTRL);
}

static int sparse_cnn_finish(struct accel_device *ac, size_t beats)
{
	struct sparse_cnn *sc = accel_priv(ac);
	void __iomem *regs = accel_regs(ac);
	u32 status;
	int ret;

	ret = readl_poll_timeout(regs + REG_STATUS, status, status & STATUS_DONE,
				 1, DONE_TIMEOUT_US);
	if (ret) {
		dev_err(accel_dev(ac),
			"the transfer completed but the tile did not; status 0x%08x\n",
			status);
		return ret;
	}

	sc->acc = (s32)readl(regs + REG_ACC);
	sc->skip = readl(regs + REG_SKIP);
	return 0;
}

static ssize_t sparse_cnn_result(struct accel_device *ac, char __user *to,
				 size_t count)
{
	struct sparse_cnn *sc = accel_priv(ac);
	struct {
		s32 acc;
		u32 skip;
	} result = { sc->acc, sc->skip };

	if (count < sizeof(result))
		return -EINVAL;
	if (copy_to_user(to, &result, sizeof(result)))
		return -EFAULT;
	return sizeof(result);
}

static const struct accel_ops sparse_cnn_ops = {
	.name = "sparse_cnn",
	.id = ID_EXPECTED,
	.beat_bytes = BEAT_BYTES,
	.duplex = false,
	.accept = sparse_cnn_accept,
	.start = sparse_cnn_start,
	.finish = sparse_cnn_finish,
	.result = sparse_cnn_result,
};

static int sparse_cnn_probe(struct platform_device *pdev)
{
	struct sparse_cnn *sc;

	sc = devm_kzalloc(&pdev->dev, sizeof(*sc), GFP_KERNEL);
	if (!sc)
		return -ENOMEM;

	return PTR_ERR_OR_ZERO(accel_probe(pdev, &sparse_cnn_ops, sc));
}

static const struct of_device_id sparse_cnn_of_match[] = {
	{ .compatible = "xlnx,sparse-cnn-axi-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, sparse_cnn_of_match);

static struct platform_driver sparse_cnn_driver = {
	.driver = {
		.name = "sparse_cnn",
		.of_match_table = sparse_cnn_of_match,
	},
	.probe = sparse_cnn_probe,
};
module_platform_driver(sparse_cnn_driver);

MODULE_DESCRIPTION("Register layer for the sparse CNN accelerator");
MODULE_LICENSE("GPL");
