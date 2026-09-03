# HP OMEN 17-cb0xxx (board 8603) power control on Linux

Working `platform_profile`, and the real reason this laptop sat at 45 W under Linux:
the embedded controller clamps the CPU package to 45 W in **every** mode once the
host has been silent for about six minutes, and only a reboot releases it. HP's
OMEN Gaming Hub keeps the EC talking with a WMI heartbeat; nothing on Linux did.

This repository has the fix (three patches to the `hp-wmi` kernel driver plus a small
RAPL follower), the measurements behind it, and the decompiled firmware paths that
explain them. Everything was measured on one machine:

| | |
|---|---|
| Model | OMEN by HP Laptop 17-cb0xxx (Santorini) |
| Board (`/sys/class/dmi/id/board_name`) | **8603** |
| BIOS | F.53 |
| CPU / GPU | i7-9750H / RTX 2080 (no iGPU) |
| Linux | Arch, kernel 7.1.9 |

## The short version

| State | Sustained, 12-thread load | Clock |
|---|---|---|
| Windows, Performance, OMEN Gaming Hub alive | **77 W** | 4.0 GHz |
| Windows, Balanced | 45 W | 3.2 GHz |
| Windows, Performance, OMEN killed 6 min earlier | 45 W (latched) | 3.1 GHz |
| Windows, Performance, OMEN killed, WMI heartbeat only | **77 W** | 4.0 GHz |
| Linux, any profile, before this work | 45 W (latched) | 2.7 GHz |

- The mode is EC byte `0x29` bits 1:0 (ACPI field `OCCM`), set by WMI `0x20008/0x1A`.
- Bit 7 of the same byte (`OCCN`) is a host-alive watchdog, set by WMI `0x20008/0x10`.
  OMEN sends it every 90 s. If it stays clear for ~6 minutes the EC clamps to 45 W over
  PECI. MSR `0x610` and the MMIO RAPL copy both keep reading 90 W while it does.
- Upstream `hp-wmi` read the profile from EC `0x95`, which on this board is a character
  of a serial string, so `platform_profile` never registered, silently.
- The firmware echoes every profile write as an Fn+P keypress, which the driver turned
  into a 900-changes-per-second feedback loop once the first bug was fixed.

## What is here

| Path | What |
|---|---|
| [`omen8603-linux/`](omen8603-linux/) | **The fix.** Patched `hp-wmi` as a DKMS module, `install.sh`, the `omen-power` RAPL follower, verify and measure tools. Start with its README. |
| [`FINDINGS-2026-09-03-windows.md`](FINDINGS-2026-09-03-windows.md) | The Windows-side ring-0 investigation that found the latch: MSR and EC reads, the DSDT methods, what OMEN Gaming Hub actually does. |
| [`FINDINGS.md`](FINDINGS.md) | The original August 2025 investigation of the WMI protocol. Partly superseded; the header says which parts. |
| [`hp-wmi-8603.md`](hp-wmi-8603.md) | The captured WMI protocol, command by command. |
| [`evidence/`](evidence/) | Decompiled DSDT (BIOS F.53), EC field map, the PowerShell tooling and raw logs from the Windows measurements. |
| [`history/`](history/) | Superseded userspace scripts and the earlier "45 Watt Ceiling" write-up. Kept for the record; do not run them. |

## Install

```bash
git clone https://github.com/PickleHik3/hp-omen-8603-linux
cd hp-omen-8603-linux/omen8603-linux
sudo ./install.sh          # needs dkms and linux-headers
sudo ./tools/omen-verify
```

Then reboot once, so the EC comes up unlatched with the heartbeat already running,
and switch modes as usual (`powerprofilesctl set performance`, or your desktop's
power-mode toggle). Details, caveats and the verification procedure are in
[`omen8603-linux/README.md`](omen8603-linux/README.md).

## Status

The driver patches and the follower are installed and verified at the register level
(mode bits and host-alive bit behave exactly as on Windows). The post-reboot Linux
wattage measurement is the next thing to land here.

## Other boards

The patches are gated on board `8603`, but the mechanism is probably not unique to it.
If you have another OMEN whose `platform_profile` is missing or whose sustained power
never rises above the base TDP, `omen8603-linux/tools/omen-verify` and the EC field
map in `evidence/` are the places to start. Issues and pull requests welcome.

## License

GPL-2.0-or-later, matching the kernel driver this builds on. `omen8603-linux/src/hp-wmi.c`
retains its original copyright notices.
