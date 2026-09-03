# Out-of-tree build of the patched hp-wmi driver for OMEN board 8603.
obj-m += hp-wmi.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f hp-wmi.ko.zst

.PHONY: all clean
