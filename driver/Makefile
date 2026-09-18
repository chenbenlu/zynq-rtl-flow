# Built on the board, not in either container: the toolchain image carries no
# kernel headers and the Vivado image is x86 against an aarch64 target.
# See README.md here and docs/adr/0005-the-accelerators-driver-is-in-scope.md.
#
# Three modules, because the two halves have different lifetimes: the transport
# is the same for every accelerator the contract carries, and a register layer
# changes with the one it describes. Built in one pass so modpost resolves the
# register layers against the transport's exported symbols; loaded in that order
# too — see README.md.

obj-m += accel_transport.o
obj-m += sparse_cnn.o
obj-m += relu.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
