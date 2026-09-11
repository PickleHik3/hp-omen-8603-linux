# Out-of-tree build of the patched hp-wmi driver for OMEN board 8603.
obj-m += hp-wmi.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
PWD  := $(shell pwd)

# Kernels built with clang (CachyOS linux-cachyos*, anything with LTO) reject
# gcc for out-of-tree modules: the kbuild cflags are clang-only. Follow the
# kernel's own toolchain choice unless LLVM= was given explicitly.
ifeq ($(origin LLVM),undefined)
ifeq ($(shell grep -qs '^CONFIG_CC_IS_CLANG=y' $(KDIR)/.config && echo y),y)
LLVM := 1
endif
endif
KBUILD_TOOLCHAIN := $(if $(LLVM),LLVM=$(LLVM))

all:
	$(MAKE) -C $(KDIR) M=$(PWD) $(KBUILD_TOOLCHAIN) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) $(KBUILD_TOOLCHAIN) clean
	rm -f hp-wmi.ko.zst

.PHONY: all clean
