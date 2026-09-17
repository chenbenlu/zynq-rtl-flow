# Built on the board, not in either container: the toolchain image carries no
# kernel headers and the Vivado image is x86 against an aarch64 target.
# See README.md here and docs/adr/0005-the-accelerators-driver-is-in-scope.md.

obj-m += sparse_cnn.o

KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
