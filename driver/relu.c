// SPDX-License-Identifier: GPL-2.0
/*
 * relu — the register layer for the Leaky ReLU accelerator.
 *
 * The other shape from sparse_cnn: it transforms a tile beat by beat and sends
 * it back on `m_axis`, so the results come off the DMA's return path rather
 * than out of a register, and read() gives back the transformed tile.
 *
 * Its map is docs/register-map-relu.md, and it is not the first accelerator's
 * map with different names. There is no START — a tile begins when its first
 * beat arrives — and EN is bit 0 where sparse_cnn_axi uses bit 2. The ID
 * register the transport checks is what stops a driver applying one layout to
 * the other.
 *
 * The negative slope is the one writable field either accelerator has. It is a
 * property of the accelerator rather than of a tile, so it is a sysfs attribute
 * on the platform device and not part of the tile that gets written:
 *
 *   /sys/class/misc/relu/device/slope
 */

#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/sysfs.h>
#include <linux/uaccess.h>

#include "accel_transport.h"

#define REG_CTRL   0x04
#define REG_STATUS 0x08
#define REG_SLOPE  0x0c
#define REG_COUNT  0x10

#define ID_EXPECTED 0x524C0100u

#define CTRL_EN BIT(0)

#define STATUS_BUSY BIT(0)
#define STATUS_DONE BIT(1)

/* SLOPE is an unsigned Q0.8 fraction; bits above 7 are not storage. */
#define SLOPE_MAX 0xffu

/* DATA_W: one signed activation per beat, in and out. */
#define BEAT_BYTES 1

/*
 * BUSY spans the pipeline and falls when the final beat leaves, so DONE is up
 * by the time the return transfer reports complete. The allowance is for the
 * few cycles between the two.
 */
#define DONE_TIMEOUT_US 10000

static int relu_accept(struct accel_device *ac)
{
	if (readl(accel_regs(ac) + REG_STATUS) & STATUS_BUSY)
		return -EBUSY;
	return 0;
}

static void relu_start(struct accel_device *ac)
{
	/*
	 * EN and nothing else. There is no START — a tile begins when its first
	 * beat arrives — and EN is bit 0 here where sparse_cnn_axi puts it at
	 * bit 2. It is a level that resets high, so this write changes nothing
	 * on a healthy accelerator; it is here so that one left disabled fails
	 * as a disabled accelerator rather than as a transfer that times out.
	 */
	writel(CTRL_EN, accel_regs(ac) + REG_CTRL);
}

static int relu_finish(struct accel_device *ac, size_t beats)
{
	void __iomem *regs = accel_regs(ac);
	u32 status, count;
	int ret;

	ret = readl_poll_timeout(regs + REG_STATUS, status, status & STATUS_DONE,
				 1, DONE_TIMEOUT_US);
	if (ret) {
		dev_err(accel_dev(ac),
			"the transfers completed but the tile did not; status 0x%08x\n",
			status);
		return ret;
	}

	/*
	 * COUNT is the tile boundary as the accelerator saw it, and it is the
	 * only thing that can see a short tile: a completed AXI DMA descriptor
	 * carries no residue, so a return transfer that ended early on an
	 * unexpected tlast looks exactly like one that filled the buffer.
	 */
	count = readl(regs + REG_COUNT);
	if (count != beats) {
		dev_err(accel_dev(ac),
			"sent %zu beats and the accelerator counted %u\n", beats,
			count);
		return -EIO;
	}
	return 0;
}

static ssize_t relu_result(struct accel_device *ac, char __user *to,
			   size_t count)
{
	size_t bytes;
	const void *tile = accel_received(ac, &bytes);

	if (!bytes)
		return 0;
	if (count < bytes)
		return -EINVAL;
	if (copy_to_user(to, tile, bytes))
		return -EFAULT;
	return bytes;
}

static const struct accel_ops relu_ops = {
	.name = "relu",
	.id = ID_EXPECTED,
	.beat_bytes = BEAT_BYTES,
	.duplex = true,
	.accept = relu_accept,
	.start = relu_start,
	.finish = relu_finish,
	.result = relu_result,
};

static ssize_t slope_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct accel_device *ac = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%u\n", readl(accel_regs(ac) + REG_SLOPE));
}

static ssize_t slope_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	struct accel_device *ac = dev_get_drvdata(dev);
	u32 slope;
	int ret;

	ret = kstrtou32(buf, 0, &slope);
	if (ret)
		return ret;
	/*
	 * Refused rather than truncated: the accelerator would keep the low
	 * eight bits and read back a number nobody wrote.
	 */
	if (slope > SLOPE_MAX)
		return -ERANGE;

	/*
	 * Held against the tile path, because the accelerator applies a slope
	 * write on the next beat it accepts rather than deferring it to the next
	 * tile. Without this a write could split one tile between two slopes.
	 */
	accel_lock(ac);
	writel(slope, accel_regs(ac) + REG_SLOPE);
	accel_unlock(ac);
	return count;
}
static DEVICE_ATTR_RW(slope);

static struct attribute *relu_attrs[] = {
	&dev_attr_slope.attr,
	NULL,
};

static const struct attribute_group relu_group = {
	.attrs = relu_attrs,
};

static int relu_probe(struct platform_device *pdev)
{
	struct accel_device *ac;

	ac = accel_probe(pdev, &relu_ops, NULL);
	if (IS_ERR(ac))
		return PTR_ERR(ac);

	/*
	 * Added after the accelerator is claimed, not through the driver's
	 * dev_groups: those appear before probe runs, and slope_show would then
	 * be reachable before there is anything for dev_get_drvdata to return.
	 */
	return devm_device_add_group(&pdev->dev, &relu_group);
}

static const struct of_device_id relu_of_match[] = {
	{ .compatible = "xlnx,relu-axi-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, relu_of_match);

static struct platform_driver relu_driver = {
	.driver = {
		.name = "relu",
		.of_match_table = relu_of_match,
	},
	.probe = relu_probe,
};
module_platform_driver(relu_driver);

MODULE_DESCRIPTION("Register layer for the Leaky ReLU accelerator");
MODULE_LICENSE("GPL");
