// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * omen-wmi-lab - issue arbitrary HP BIOS WMI commands from userspace.
 *
 * Investigation tool for OMEN 17-cb0xxx (board 8603). hp-wmi only ever sends
 * the thermal-profile command (0x1A). OMEN Gaming Hub's captured call trace
 * shows it also pairs 0x27, follows with 0x10, and polls 0x23 every 30 s -
 * a possible "host is present" handshake. This module exposes the same
 * hp_wmi_perform_query() path so that sequence can be reproduced and tested
 * without rebuilding a driver for every experiment.
 *
 *   echo '0x20008 0x1a 0 ff01' > /sys/kernel/debug/omen-wmi/call
 *   cat /sys/kernel/debug/omen-wmi/result
 *
 * Fields: <command> <commandtype> <outsize> <hex input bytes>
 *
 * This writes to firmware. It is a debugging aid, not a production driver.
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/acpi.h>
#include <linux/debugfs.h>
#include <linux/hex.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/wmi.h>
#include <linux/pci.h>
#include <linux/io.h>

#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
#define LAB_MAX_DATA 128

struct bios_args {
	u32 signature;
	u32 command;
	u32 commandtype;
	u32 datasize;
	u8 data[];
};

struct bios_return {
	u32 sigpass;
	u32 return_code;
};

/*
 * MCHBAR MMIO window - READ ONLY.
 *
 * The package RAPL limit has an MMIO copy at MCHBAR+0x59A0 alongside MSR
 * 0x610. On some platforms the PCU honours the MMIO copy and ignores the MSR,
 * which is why ThrottleStop has a SyncMMIO option (enabled in this machine's
 * ThrottleStop.ini). Linux binds no intel-rapl-mmio driver here, so the
 * register is otherwise unreachable, and CONFIG_STRICT_DEVMEM blocks /dev/mem.
 *
 * This interface deliberately provides NO write path: it exists only to find
 * out what the register holds. Reads are confined to the MCHBAR window.
 */
#define MCHBAR_SIZE   0x8000
static phys_addr_t mchbar_base;
static void __iomem *mchbar;

static DEFINE_MUTEX(lab_lock);
static struct dentry *lab_dir;
static char lab_result[512] = "no call issued yet\n";

static inline int encode_outsize_for_pvsz(int outsize)
{
	if (outsize > 4096)
		return -EINVAL;
	if (outsize > 1024)
		return 5;
	if (outsize > 128)
		return 4;
	if (outsize > 4)
		return 3;
	if (outsize > 0)
		return 2;
	return 1;
}

/* Mirrors hp_wmi_perform_query() exactly. */
static int lab_query(u32 command, u32 commandtype, void *buffer,
		     int insize, int outsize)
{
	struct acpi_buffer input, output = { ACPI_ALLOCATE_BUFFER, NULL };
	struct bios_return *bios_return;
	union acpi_object *obj = NULL;
	struct bios_args *args = NULL;
	int mid, actual_insize, actual_outsize;
	size_t bios_args_size;
	int ret;

	mid = encode_outsize_for_pvsz(outsize);
	if (mid < 0)
		return mid;

	actual_insize = max(insize, 128);
	bios_args_size = struct_size(args, data, actual_insize);
	args = kmalloc(bios_args_size, GFP_KERNEL);
	if (!args)
		return -ENOMEM;

	input.length = bios_args_size;
	input.pointer = args;

	args->signature = 0x55434553;
	args->command = command;
	args->commandtype = commandtype;
	args->datasize = insize;
	memcpy(args->data, buffer, flex_array_size(args, data, insize));

	ret = wmi_evaluate_method(HPWMI_BIOS_GUID, 0, mid, &input, &output);
	if (ret)
		goto out_free;

	obj = output.pointer;
	if (!obj) {
		ret = -EINVAL;
		goto out_free;
	}
	if (obj->type != ACPI_TYPE_BUFFER) {
		ret = -EINVAL;
		goto out_free;
	}

	bios_return = (struct bios_return *)obj->buffer.pointer;
	ret = bios_return->return_code;
	if (ret)
		goto out_free;

	if (!outsize)
		goto out_free;

	actual_outsize = min(outsize,
			     (int)(obj->buffer.length - sizeof(*bios_return)));
	memcpy(buffer, obj->buffer.pointer + sizeof(*bios_return), actual_outsize);
	memset(buffer + actual_outsize, 0, outsize - actual_outsize);

out_free:
	kfree(obj);
	kfree(args);
	return ret;
}

static ssize_t lab_call_write(struct file *f, const char __user *ubuf,
			      size_t len, loff_t *off)
{
	char *buf, *p, *tok;
	u8 data[LAB_MAX_DATA] = {};
	u32 command, commandtype;
	int outsize, insize = 0, ret, i, n;

	if (len > 1024)
		return -EINVAL;
	buf = memdup_user_nul(ubuf, len);
	if (IS_ERR(buf))
		return PTR_ERR(buf);
	p = strim(buf);

	ret = -EINVAL;
	tok = strsep(&p, " \t");
	if (!tok || kstrtou32(tok, 0, &command))
		goto out;
	tok = strsep(&p, " \t");
	if (!tok || kstrtou32(tok, 0, &commandtype))
		goto out;
	tok = strsep(&p, " \t");
	if (!tok || kstrtoint(tok, 0, &outsize) || outsize < 0 || outsize > LAB_MAX_DATA)
		goto out;

	/* remaining token: hex byte string, e.g. ff01 */
	tok = p ? strim(p) : NULL;
	if (tok && *tok) {
		n = strlen(tok);
		if (n % 2 || n / 2 > LAB_MAX_DATA)
			goto out;
		if (hex2bin(data, tok, n / 2))
			goto out;
		insize = n / 2;
	}

	guard(mutex)(&lab_lock);
	ret = lab_query(command, commandtype, data, insize, outsize);

	n = scnprintf(lab_result, sizeof(lab_result),
		      "cmd=0x%x type=0x%x insize=%d outsize=%d -> rc=%d\nout:",
		      command, commandtype, insize, outsize, ret);
	for (i = 0; i < outsize && n < sizeof(lab_result) - 8; i++)
		n += scnprintf(lab_result + n, sizeof(lab_result) - n, " %02x", data[i]);
	scnprintf(lab_result + n, sizeof(lab_result) - n, "\n");

	pr_info("cmd=0x%x type=0x%x -> rc=%d\n", command, commandtype, ret);
	ret = len;
out:
	kfree(buf);
	return ret;
}

/* Read-only. Accepts an address inside MCHBAR; returns its 64-bit contents. */
static ssize_t lab_mmio_write(struct file *f, const char __user *ubuf,
			      size_t len, loff_t *off)
{
	char *buf;
	u64 addr, val;
	int ret;

	if (!mchbar)
		return -ENODEV;
	if (len > 64)
		return -EINVAL;
	buf = memdup_user_nul(ubuf, len);
	if (IS_ERR(buf))
		return PTR_ERR(buf);

	ret = -EINVAL;
	if (kstrtou64(strim(buf), 0, &addr))
		goto out;
	if (addr < mchbar_base || addr + 8 > mchbar_base + MCHBAR_SIZE) {
		pr_warn("0x%llx is outside the MCHBAR window\n", addr);
		goto out;
	}
	if (addr & 7)
		goto out;

	scoped_guard(mutex, &lab_lock) {
		val = readq(mchbar + (addr - mchbar_base));
		scnprintf(lab_result, sizeof(lab_result),
			  "mmio 0x%llx = 0x%016llx\n", addr, val);
	}
	ret = len;
out:
	kfree(buf);
	return ret;
}

static const struct file_operations lab_mmio_fops = {
	.owner = THIS_MODULE,
	.write = lab_mmio_write,
	.llseek = noop_llseek,
};

static void lab_map_mchbar(void)
{
	struct pci_dev *host;
	u32 lo, hi;
	u64 v;

	host = pci_get_domain_bus_and_slot(0, 0, PCI_DEVFN(0, 0));
	if (!host)
		return;
	pci_read_config_dword(host, 0x48, &lo);
	pci_read_config_dword(host, 0x4c, &hi);
	pci_dev_put(host);

	v = ((u64)hi << 32) | lo;
	if (!(v & 1)) {
		pr_warn("MCHBAR is not enabled\n");
		return;
	}
	mchbar_base = v & ~0x7fffULL;
	/* ioremap, not request_mem_region: the firmware owns this window */
	mchbar = ioremap(mchbar_base, MCHBAR_SIZE);
	if (mchbar)
		pr_info("MCHBAR mapped read-only at 0x%llx\n", (u64)mchbar_base);
}

static ssize_t lab_result_read(struct file *f, char __user *ubuf,
			       size_t len, loff_t *off)
{
	guard(mutex)(&lab_lock);
	return simple_read_from_buffer(ubuf, len, off, lab_result,
				       strlen(lab_result));
}

static const struct file_operations lab_call_fops = {
	.owner = THIS_MODULE,
	.write = lab_call_write,
	.llseek = noop_llseek,
};

static const struct file_operations lab_result_fops = {
	.owner = THIS_MODULE,
	.read = lab_result_read,
	.llseek = default_llseek,
};

static int __init lab_init(void)
{
	if (!wmi_has_guid(HPWMI_BIOS_GUID)) {
		pr_err("HP BIOS WMI GUID not present\n");
		return -ENODEV;
	}
	lab_dir = debugfs_create_dir("omen-wmi", NULL);
	debugfs_create_file("call", 0200, lab_dir, NULL, &lab_call_fops);
	debugfs_create_file("result", 0400, lab_dir, NULL, &lab_result_fops);
	debugfs_create_file("mmio_read", 0200, lab_dir, NULL, &lab_mmio_fops);
	lab_map_mchbar();
	pr_info("loaded; write to /sys/kernel/debug/omen-wmi/call\n");
	return 0;
}

static void __exit lab_exit(void)
{
	debugfs_remove_recursive(lab_dir);
	if (mchbar)
		iounmap(mchbar);
}

module_init(lab_init);
module_exit(lab_exit);
MODULE_DESCRIPTION("Arbitrary HP BIOS WMI command issuer for OMEN board 8603");
MODULE_LICENSE("GPL");
