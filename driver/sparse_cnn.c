// SPDX-License-Identifier: GPL-2.0
/*
 * sparse_cnn — PS-side driver for the sparse CNN accelerator.
 *
 * Submits one tile and reports what the accelerator made of it. The control
 * path is the AXI4-Lite register map in docs/register-map.md, which is the
 * specification this answers to; the operands travel over AXI4-Stream from an
 * AXI DMA, which is why this is a kernel module rather than a program: the
 * board's kernel is built with CONFIG_STRICT_DEVMEM, so userspace cannot hand
 * the DMA a buffer to read from (docs/adr/0005-...).
 *
 * The interface to userspace is one character device:
 *
 *   write()  the tile's operand pairs, one little-endian 16-bit beat each,
 *            bits 15:8 the activation and 7:0 the weight. Runs the tile and
 *            returns once it has completed.
 *   read()   eight bytes: the accumulator as a signed 32-bit value, then the
 *            zero-skip count. The last completed tile's, per the register map.
 *
 * Neither call uses the file offset: a tile is a transaction, not a position in
 * a stream.
 */

#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>

#define REG_ID     0x00
#define REG_CTRL   0x04
#define REG_STATUS 0x08
#define REG_ACC    0x0c
#define REG_SKIP   0x10

#define ID_EXPECTED 0x53500100u

#define CTRL_START BIT(0)
#define CTRL_EN    BIT(2)

#define STATUS_BUSY BIT(0)
#define STATUS_DONE BIT(1)

#define BEAT_BYTES 2
#define TILE_MAX_BEATS 4096
#define TILE_BUF_BYTES (TILE_MAX_BEATS * BEAT_BYTES)

#define DMA_TIMEOUT_MS 1000
/*
 * The accelerator latches its result as it absorbs the tlast beat, so DONE is
 * up by the time the DMA reports the transfer complete. This is the allowance
 * for the few cycles between the two, not a transfer's worth of patience.
 */
#define DONE_TIMEOUT_US 10000

struct sparse_cnn {
	struct device *dev;
	void __iomem *regs;
	struct dma_chan *tx;
	struct device *dma_dev;
	void *buf;
	dma_addr_t buf_dma;
	struct mutex lock;
	struct miscdevice misc;
	s32 acc;
	u32 skip;
};

static void sparse_cnn_dma_done(void *arg)
{
	complete(arg);
}

static int sparse_cnn_run_tile(struct sparse_cnn *sc, size_t bytes)
{
	struct dma_async_tx_descriptor *desc;
	DECLARE_COMPLETION_ONSTACK(finished);
	dma_cookie_t cookie;
	u32 status;
	int ret;

	if (readl(sc->regs + REG_STATUS) & STATUS_BUSY)
		return -EBUSY;

	desc = dmaengine_prep_slave_single(sc->tx, sc->buf_dma, bytes,
					   DMA_MEM_TO_DEV,
					   DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc)
		return -EIO;

	desc->callback = sparse_cnn_dma_done;
	desc->callback_param = &finished;

	/* START, then the beats, then wait on DONE — docs/register-map.md. */
	writel(CTRL_EN | CTRL_START, sc->regs + REG_CTRL);

	cookie = dmaengine_submit(desc);
	ret = dma_submit_error(cookie);
	if (ret) {
		dev_err(sc->dev, "could not submit the tile's transfer\n");
		return ret;
	}
	dma_async_issue_pending(sc->tx);

	if (!wait_for_completion_timeout(&finished,
					 msecs_to_jiffies(DMA_TIMEOUT_MS))) {
		dmaengine_terminate_sync(sc->tx);
		dev_err(sc->dev,
			"the transfer did not complete; the accelerator reports status 0x%08x\n",
			readl(sc->regs + REG_STATUS));
		return -ETIMEDOUT;
	}

	ret = readl_poll_timeout(sc->regs + REG_STATUS, status,
				 status & STATUS_DONE, 1, DONE_TIMEOUT_US);
	if (ret) {
		dev_err(sc->dev,
			"the transfer completed but the tile did not; status 0x%08x\n",
			status);
		return ret;
	}

	sc->acc = (s32)readl(sc->regs + REG_ACC);
	sc->skip = readl(sc->regs + REG_SKIP);
	return 0;
}

static ssize_t sparse_cnn_write(struct file *file, const char __user *from,
				size_t count, loff_t *ppos)
{
	struct sparse_cnn *sc =
		container_of(file->private_data, struct sparse_cnn, misc);
	int ret;

	if (!count || count % BEAT_BYTES)
		return -EINVAL;
	if (count > TILE_BUF_BYTES)
		return -EMSGSIZE;

	if (mutex_lock_interruptible(&sc->lock))
		return -ERESTARTSYS;

	if (copy_from_user(sc->buf, from, count)) {
		ret = -EFAULT;
		goto out;
	}

	ret = sparse_cnn_run_tile(sc, count);
out:
	mutex_unlock(&sc->lock);
	return ret ? ret : count;
}

static ssize_t sparse_cnn_read(struct file *file, char __user *to, size_t count,
			       loff_t *ppos)
{
	struct sparse_cnn *sc =
		container_of(file->private_data, struct sparse_cnn, misc);
	struct {
		s32 acc;
		u32 skip;
	} result;

	if (count < sizeof(result))
		return -EINVAL;

	if (mutex_lock_interruptible(&sc->lock))
		return -ERESTARTSYS;
	result.acc = sc->acc;
	result.skip = sc->skip;
	mutex_unlock(&sc->lock);

	if (copy_to_user(to, &result, sizeof(result)))
		return -EFAULT;
	return sizeof(result);
}

static const struct file_operations sparse_cnn_fops = {
	.owner = THIS_MODULE,
	.read = sparse_cnn_read,
	.write = sparse_cnn_write,
	.llseek = no_llseek,
};

static void sparse_cnn_release_dma(void *data)
{
	struct sparse_cnn *sc = data;

	dma_free_coherent(sc->dma_dev, TILE_BUF_BYTES, sc->buf, sc->buf_dma);
	dma_release_channel(sc->tx);
}

static void sparse_cnn_deregister_misc(void *data)
{
	misc_deregister(data);
}

static int sparse_cnn_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct sparse_cnn *sc;
	u32 id;
	int ret;

	sc = devm_kzalloc(dev, sizeof(*sc), GFP_KERNEL);
	if (!sc)
		return -ENOMEM;
	sc->dev = dev;
	mutex_init(&sc->lock);

	sc->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(sc->regs))
		return PTR_ERR(sc->regs);

	/*
	 * The ID register reads before anything has been written, so the first
	 * thing this driver does is confirm what it is talking to. A bitstream
	 * that does not answer with it is not the design this map describes, and
	 * binding to it would produce wrong results rather than an error.
	 */
	id = readl(sc->regs + REG_ID);
	if (id != ID_EXPECTED) {
		dev_err(dev, "ID reads 0x%08x, not the specified 0x%08x\n", id,
			ID_EXPECTED);
		return -ENODEV;
	}

	sc->tx = dma_request_chan(dev, "tx");
	if (IS_ERR(sc->tx))
		return dev_err_probe(dev, PTR_ERR(sc->tx),
				     "no stream channel to submit tiles on\n");

	/*
	 * Coherent rather than streaming: HP0 is not cache-coherent, so a buffer
	 * the CPU wrote through its cache would leave the DMA reading whatever
	 * DDR happened to hold. A tile is small enough that an uncached buffer
	 * costs nothing worth reclaiming.
	 */
	sc->dma_dev = dmaengine_get_dma_device(sc->tx);
	sc->buf = dma_alloc_coherent(sc->dma_dev, TILE_BUF_BYTES, &sc->buf_dma,
				     GFP_KERNEL);
	if (!sc->buf) {
		dma_release_channel(sc->tx);
		return -ENOMEM;
	}

	ret = devm_add_action_or_reset(dev, sparse_cnn_release_dma, sc);
	if (ret)
		return ret;

	sc->misc.minor = MISC_DYNAMIC_MINOR;
	sc->misc.name = "sparse_cnn";
	sc->misc.fops = &sparse_cnn_fops;
	sc->misc.parent = dev;
	ret = misc_register(&sc->misc);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, sparse_cnn_deregister_misc,
				       &sc->misc);
	if (ret)
		return ret;

	dev_info(dev, "ready on /dev/%s, tiles up to %d beats\n",
		 sc->misc.name, TILE_MAX_BEATS);
	return 0;
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

MODULE_DESCRIPTION("PS-side driver for the sparse CNN accelerator");
MODULE_LICENSE("GPL");
