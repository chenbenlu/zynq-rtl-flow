/* SPDX-License-Identifier: GPL-2.0 */
/*
 * accel_transport — what every conforming accelerator's driver gets for free.
 *
 * The transport layer moves a tile between memory and the accelerator's
 * stream and presents it to userspace as one character device. It knows the
 * accelerator contract (docs/accelerator-contract.md) and nothing else: the
 * AXI4-Lite slave at resource 0, the ID register at offset 0x00, the AXI DMA
 * on the other side of `s_axis`, and the optional return path on `m_axis`.
 *
 * Everything above offset 0x00 belongs to one accelerator's register map, and
 * a register layer supplies it as four answers — whether a tile may start, what
 * makes it start, how to tell it finished, and what read() gives back. A
 * register layer owns the platform driver and the `compatible` string it binds
 * to, because that is the part that changes with the accelerator.
 */
#ifndef ACCEL_TRANSPORT_H
#define ACCEL_TRANSPORT_H

#include <linux/types.h>

struct accel_device;
struct platform_device;
struct device;

/* Offset 0x00 is the contract's, so the transport reads it and no one else. */
#define ACCEL_REG_ID 0x00

/*
 * The longest tile the transport will carry. It sizes the coherent buffers,
 * which are allocated once at probe rather than per tile — a tile is small and
 * an allocation on the submit path would be the slowest thing on it.
 */
#define ACCEL_MAX_BEATS 4096

struct accel_ops {
	/* The character device this accelerator answers on: /dev/<name>. */
	const char *name;
	/* What the contract's ID register must read for this to be the design. */
	u32 id;
	/* One stream beat, in bytes. The tile buffers are sized from it. */
	size_t beat_bytes;
	/* The accelerator answers on `m_axis` and needs the return path. */
	bool duplex;

	/* Whether a tile may start now. Optional. */
	int (*accept)(struct accel_device *ac);
	/* The register writes that must land before the first beat. Optional. */
	void (*start)(struct accel_device *ac);
	/* Every beat has moved: wait for the accelerator and latch. Optional. */
	int (*finish)(struct accel_device *ac, size_t beats);
	/* Required. */
	ssize_t (*result)(struct accel_device *ac, char __user *to, size_t count);
};

/*
 * Claim the accelerator and publish its character device. Everything taken is
 * devm-managed against the platform device, so a register layer's probe has
 * nothing to unwind — it returns the error and stops.
 *
 * The handle is also the platform device's driver data, which is how a sysfs
 * attribute reaches it: dev_get_drvdata() is valid from the moment this
 * returns, and only from then.
 */
struct accel_device *accel_probe(struct platform_device *pdev,
				 const struct accel_ops *ops, void *priv);

struct device *accel_dev(struct accel_device *ac);
void __iomem *accel_regs(struct accel_device *ac);
void *accel_priv(struct accel_device *ac);

/* The last tile's results as they came back on `m_axis`. NULL if not duplex. */
const void *accel_received(struct accel_device *ac, size_t *bytes);

/*
 * Hold tiles off. A register layer whose accelerator takes a writable
 * parameter needs it: the hardware applies such a write on the next beat it
 * accepts rather than deferring it, so a write that lands mid-tile would split
 * that tile between two settings.
 */
void accel_lock(struct accel_device *ac);
void accel_unlock(struct accel_device *ac);

#endif /* ACCEL_TRANSPORT_H */
