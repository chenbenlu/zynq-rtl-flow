// SPDX-License-Identifier: GPL-2.0
/*
 * accel_transport — the half of a PS-side driver that does not change with the
 * accelerator.
 *
 * This is a dmaengine client and a character device. It exists as a kernel
 * module rather than a program because the board's kernel is built with
 * CONFIG_STRICT_DEVMEM: /dev/mem maps the accelerator's AXI4-Lite registers,
 * which are device memory, but not the system memory a DMA descriptor points
 * at, so a tile's operands cannot be handed to the DMA from userspace at all
 * (docs/adr/0005-the-accelerators-driver-is-in-scope.md).
 *
 * The interface to userspace is one character device per accelerator:
 *
 *   write()  one tile, as stream beats. Runs it and returns once it completes.
 *   read()   the tile's results, in whatever shape that accelerator reports
 *            them — a register layer decides.
 *
 * Neither call uses the file offset: a tile is a transaction, not a position in
 * a stream. One tile at a time; concurrent writers are serialised.
 */

#include <linux/completion.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/uaccess.h>

#include "accel_transport.h"

#define DMA_TIMEOUT_MS 1000

struct accel_stream {
	struct dma_chan *chan;
	/*
	 * The DMA controller's device, not the accelerator's: a coherent buffer
	 * is allocated for whatever will master the bus to reach it.
	 */
	struct device *dev;
	void *buf;
	dma_addr_t handle;
	size_t bytes;
};

struct accel_device {
	struct device *dev;
	const struct accel_ops *ops;
	void *priv;

	void __iomem *regs;
	struct accel_stream tx;
	struct accel_stream rx;
	size_t received;

	/* One tile at a time: the buffers, the results and the registers. */
	struct mutex lock;
	struct miscdevice misc;
};

struct device *accel_dev(struct accel_device *ac)
{
	return ac->dev;
}
EXPORT_SYMBOL_GPL(accel_dev);

void __iomem *accel_regs(struct accel_device *ac)
{
	return ac->regs;
}
EXPORT_SYMBOL_GPL(accel_regs);

void *accel_priv(struct accel_device *ac)
{
	return ac->priv;
}
EXPORT_SYMBOL_GPL(accel_priv);

const void *accel_received(struct accel_device *ac, size_t *bytes)
{
	*bytes = ac->received;
	return ac->rx.buf;
}
EXPORT_SYMBOL_GPL(accel_received);

void accel_lock(struct accel_device *ac)
{
	mutex_lock(&ac->lock);
}
EXPORT_SYMBOL_GPL(accel_lock);

void accel_unlock(struct accel_device *ac)
{
	mutex_unlock(&ac->lock);
}
EXPORT_SYMBOL_GPL(accel_unlock);

static void accel_transfer_done(void *arg)
{
	complete(arg);
}

static int accel_wait(struct accel_device *ac, struct dma_chan *chan,
		      struct completion *done, const char *direction)
{
	if (wait_for_completion_timeout(done, msecs_to_jiffies(DMA_TIMEOUT_MS)))
		return 0;

	dmaengine_terminate_sync(chan);
	dev_err(ac->dev, "the tile's %s transfer did not complete\n", direction);
	return -ETIMEDOUT;
}

static int accel_run_tile(struct accel_device *ac, size_t bytes)
{
	struct dma_async_tx_descriptor *tx_desc, *rx_desc = NULL;
	DECLARE_COMPLETION_ONSTACK(sent);
	DECLARE_COMPLETION_ONSTACK(returned);
	size_t beats = bytes / ac->ops->beat_bytes;
	dma_cookie_t cookie;
	int ret;

	ac->received = 0;

	if (ac->ops->accept) {
		ret = ac->ops->accept(ac);
		if (ret)
			return ret;
	}

	if (ac->rx.chan) {
		rx_desc = dmaengine_prep_slave_single(ac->rx.chan, ac->rx.handle,
						      bytes, DMA_DEV_TO_MEM,
						      DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
		if (!rx_desc)
			return -EIO;
		rx_desc->callback = accel_transfer_done;
		rx_desc->callback_param = &returned;
	}

	tx_desc = dmaengine_prep_slave_single(ac->tx.chan, ac->tx.handle, bytes,
					      DMA_MEM_TO_DEV,
					      DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!tx_desc) {
		ret = -EIO;
		goto discard;
	}
	tx_desc->callback = accel_transfer_done;
	tx_desc->callback_param = &sent;

	if (rx_desc) {
		cookie = dmaengine_submit(rx_desc);
		ret = dma_submit_error(cookie);
		if (ret) {
			dev_err(ac->dev, "could not queue the tile's return transfer\n");
			goto discard;
		}
	}

	cookie = dmaengine_submit(tx_desc);
	ret = dma_submit_error(cookie);
	if (ret) {
		dev_err(ac->dev, "could not queue the tile's transfer\n");
		goto discard;
	}

	/*
	 * Nothing above this line can move a beat — a submitted descriptor waits
	 * for issue_pending — so the accelerator is started only once every step
	 * that can fail has succeeded. Started earlier, a failed submit would
	 * leave it waiting for a tile that is no longer coming, and every tile
	 * after it would be refused as busy.
	 */
	if (ac->ops->start)
		ac->ops->start(ac);

	/*
	 * The return path is released before the tile is sent. Result beats can
	 * reach the S2MM channel as soon as the first operands arrive, and a
	 * channel with nothing issued to it has nowhere to put them.
	 */
	if (rx_desc)
		dma_async_issue_pending(ac->rx.chan);
	dma_async_issue_pending(ac->tx.chan);

	ret = accel_wait(ac, ac->tx.chan, &sent, "outgoing");
	if (ret)
		goto discard;

	if (rx_desc) {
		ret = accel_wait(ac, ac->rx.chan, &returned, "returning");
		if (ret)
			return ret;
	}

	if (ac->ops->finish) {
		ret = ac->ops->finish(ac, beats);
		if (ret)
			return ret;
	}

	/*
	 * The length is the tile's, not something the transfer reported: a
	 * completed AXI DMA descriptor carries no residue, so an accelerator
	 * that returned fewer beats than it was given would look identical
	 * here. What catches that is the register layer's own tile-boundary
	 * observable, which finish() has just agreed with — publishing the
	 * results only now is what keeps read() from handing back a tile that
	 * was rejected.
	 */
	if (rx_desc)
		ac->received = bytes;
	return 0;

discard:
	if (rx_desc)
		dmaengine_terminate_sync(ac->rx.chan);
	return ret;
}

static ssize_t accel_write(struct file *file, const char __user *from,
			   size_t count, loff_t *ppos)
{
	struct accel_device *ac =
		container_of(file->private_data, struct accel_device, misc);
	int ret;

	if (!count || count % ac->ops->beat_bytes)
		return -EINVAL;
	if (count > ac->tx.bytes)
		return -EMSGSIZE;

	if (mutex_lock_interruptible(&ac->lock))
		return -ERESTARTSYS;

	if (copy_from_user(ac->tx.buf, from, count)) {
		ret = -EFAULT;
		goto out;
	}

	ret = accel_run_tile(ac, count);
out:
	mutex_unlock(&ac->lock);
	return ret ? ret : count;
}

/*
 * The lock is held across the copy to userspace rather than around a bounce
 * buffer: for an accelerator that answers on a stream the result *is* the
 * receive buffer, and copying it twice to shorten a critical section that only
 * ever contends with this device's own writer buys nothing.
 */
static ssize_t accel_read(struct file *file, char __user *to, size_t count,
			  loff_t *ppos)
{
	struct accel_device *ac =
		container_of(file->private_data, struct accel_device, misc);
	ssize_t ret;

	if (mutex_lock_interruptible(&ac->lock))
		return -ERESTARTSYS;
	ret = ac->ops->result(ac, to, count);
	mutex_unlock(&ac->lock);
	return ret;
}

static const struct file_operations accel_fops = {
	.owner = THIS_MODULE,
	.read = accel_read,
	.write = accel_write,
	.llseek = no_llseek,
};

static void accel_release_chan(void *chan)
{
	dma_release_channel(chan);
}

static void accel_free_stream(void *data)
{
	struct accel_stream *s = data;

	dma_free_coherent(s->dev, s->bytes, s->buf, s->handle);
}

/*
 * Coherent rather than streaming: the PS's HP ports are not cache-coherent, so
 * a buffer the CPU wrote through its cache would leave the DMA reading whatever
 * DDR happened to hold. A tile is small enough that an uncached buffer costs
 * nothing worth reclaiming.
 */
static int accel_claim_stream(struct accel_device *ac, struct accel_stream *s,
			      const char *name, size_t bytes)
{
	int ret;

	s->chan = dma_request_chan(ac->dev, name);
	if (IS_ERR(s->chan))
		return dev_err_probe(ac->dev, PTR_ERR(s->chan),
				     "no \"%s\" stream channel to carry tiles on\n",
				     name);
	ret = devm_add_action_or_reset(ac->dev, accel_release_chan, s->chan);
	if (ret)
		return ret;

	s->dev = dmaengine_get_dma_device(s->chan);
	s->bytes = bytes;
	s->buf = dma_alloc_coherent(s->dev, bytes, &s->handle, GFP_KERNEL);
	if (!s->buf)
		return -ENOMEM;

	return devm_add_action_or_reset(ac->dev, accel_free_stream, s);
}

static void accel_deregister_misc(void *misc)
{
	misc_deregister(misc);
}

struct accel_device *accel_probe(struct platform_device *pdev,
				 const struct accel_ops *ops, void *priv)
{
	struct device *dev = &pdev->dev;
	size_t tile_bytes = ACCEL_MAX_BEATS * ops->beat_bytes;
	struct accel_device *ac;
	u32 id;
	int ret;

	if (!ops->name || !ops->beat_bytes || !ops->result) {
		dev_err(dev, "the register layer names no device, beat or result\n");
		return ERR_PTR(-EINVAL);
	}

	ac = devm_kzalloc(dev, sizeof(*ac), GFP_KERNEL);
	if (!ac)
		return ERR_PTR(-ENOMEM);
	ac->dev = dev;
	ac->ops = ops;
	ac->priv = priv;
	mutex_init(&ac->lock);
	platform_set_drvdata(pdev, ac);

	ac->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(ac->regs))
		return ERR_CAST(ac->regs);

	/*
	 * The ID register reads before anything has been written, so the first
	 * thing a driver does is confirm what it is talking to. A bitstream that
	 * does not answer with the register layer's tag is not the design that
	 * layer describes, and binding to it would produce wrong results rather
	 * than an error.
	 */
	id = readl(ac->regs + ACCEL_REG_ID);
	if (id != ops->id) {
		dev_err(dev, "ID reads 0x%08x, not the specified 0x%08x\n", id,
			ops->id);
		return ERR_PTR(-ENODEV);
	}

	ret = accel_claim_stream(ac, &ac->tx, "tx", tile_bytes);
	if (ret)
		return ERR_PTR(ret);

	if (ops->duplex) {
		ret = accel_claim_stream(ac, &ac->rx, "rx", tile_bytes);
		if (ret)
			return ERR_PTR(ret);
	}

	ac->misc.minor = MISC_DYNAMIC_MINOR;
	ac->misc.name = ops->name;
	ac->misc.fops = &accel_fops;
	ac->misc.parent = dev;
	ret = misc_register(&ac->misc);
	if (ret)
		return ERR_PTR(ret);
	ret = devm_add_action_or_reset(dev, accel_deregister_misc, &ac->misc);
	if (ret)
		return ERR_PTR(ret);

	dev_info(dev, "ready on /dev/%s, tiles up to %d beats%s\n", ops->name,
		 ACCEL_MAX_BEATS, ops->duplex ? ", results on the return path" : "");
	return ac;
}
EXPORT_SYMBOL_GPL(accel_probe);

MODULE_DESCRIPTION("Tile transport for accelerators conforming to the accelerator contract");
MODULE_LICENSE("GPL");
