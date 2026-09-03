# omen8603-linux — working `platform_profile` for OMEN 17-cb0xxx (board 8603)

Patched `hp-wmi` driver plus a small RAPL follower that give this laptop the same
power-mode behaviour under Linux that OMEN Gaming Hub gives it under Windows:
`platform_profile` works, the embedded controller is kept from clamping the CPU to
45 W, and Performance mode carries a 90 W PL1/PL2.

**Status (2026-09-03):** three driver patches and `omen-power.service` are installed
and verified in-session (mode bits and host-alive bit in EC[0x29] behave exactly as
on Windows). The one thing still to confirm is the sustained wattage after a fresh
boot: see *Verifying after a reboot* below. Expected result, from the Windows-side
measurements in `../FINDINGS-2026-09-03-windows.md`: **~77 W sustained at 4.0 GHz
all-core in performance**, against the 44.8 W every earlier Linux run produced.

### What was actually wrong

The 44.8 W ceiling documented further down was **not** this machine's design point.
It is a clamp the EC applies over PECI about six minutes after the host stops
sending WMI command `0x20008/0x10`, which the firmware's `GM10` method answers by
setting EC field **OCCN** (EC[0x29] bit 7, "host alive"). OMEN Gaming Hub sends that
command every 90 s; nothing on Linux ever did, so every Linux session latched a few
minutes after boot, and the latch survives everything except a reboot. That is why
every earlier experiment here (profile writes, MSR writes, MMIO reads, replaying the
full OMEN handshake every 2 s) measured the same 44–45 W: they all ran on a latched
EC. The full account, with the Windows ring-0 measurements and the DSDT decompile,
is `../FINDINGS-2026-09-03-windows.md` and the artifact *The EC Latch*.

### What is installed

| Piece | Where | Does |
|---|---|---|
| patch 0001 | `hp_wmi` (DKMS) | tolerate the unknown EC[0x95] value so `platform_profile` registers |
| patch 0002 | `hp_wmi` (DKMS) | ignore the Fn+P notification the firmware echoes at each profile write |
| **patch 0003** | `hp_wmi` (DKMS) | **send WMI `0x10` + `0x23` every 30 s from module load** (`omen_host_alive_secs`, 0 = off); read the profile from EC[0x29] bits 1:0 instead of EC[0x95] |
| `omen-power.service` | `/usr/local/bin/omen-power` | poll()-follow `platform_profile` and set RAPL: performance → PL1/PL2 = 90/90 W, balanced/cool → 45/90 W (what OMEN does with MSR 0x610) |

The heartbeat lives in the kernel module on purpose: `hp_wmi` loads from udev about a
minute into boot, well inside the ~6 minute latch window, it owns the WMI channel so
nothing races the driver's own calls, and it needs no `acpi_call`. On resume it fires
a heartbeat immediately.

### Verifying after a reboot

```bash
sudo omen8603-linux/tools/omen-verify          # all OK, EC[0x29] shows OCCN=1
sudo omen-power status                         # same, one screen
sudo omen-power watch 90                       # OCCN must stay 1 (or return to 1 within 30 s)
powerprofilesctl set performance
sudo omen8603-linux/tools/omen-measure         # expect ~77 W steady in performance, ~45 W in balanced
```

If performance still reads ~45 W after a clean boot with `OCCN=1` throughout, the
heartbeat alone is not sufficient on Linux and the next suspect is what OMEN does
at logon that the driver does not (`0x27` max-fan pairing, `0x21` GPU status poll).

### Earlier Linux measurements, all taken on a latched EC (kept for the record)

#### Measured (60 s load per phase, 1 s sampling, each profile run twice)

| | boost | sustained |
|---|---|---|
| performance #1 | 84–88 W @ 4.00 GHz, ~10–16 s | **44.7 W** |
| performance #2 | 84–88 W @ 4.00 GHz | **44.8 W** |
| balanced | 84–88 W @ 4.00 GHz | **44.8 W** |
| cool | — | 45 W |

Performance runs agree to 0.1 W. Performance minus balanced: **−0.1 W**. Every
profile boosts to ~88 W under PL2 for 10–16 s, then clamps to 45 W under PL1.
The profiles are functionally identical for sustained load.

#### Neither RAPL interface controls it

| profile | `MSR 0x610` PL1 | `MMIO 0xFED159A0` PL1 | delivered |
|---|---|---|---|
| balanced | 45 W | 90 W | 45 W |
| **performance** | **90 W** | **90 W** | **45 W** |
| cool | 45 W | 90 W | 45 W |

In `performance` *both* registers read 90 W and the machine still delivers 45 W,
so `min(MSR, MMIO)` does not explain it either. The MSR is inert in both
directions — forcing PL1 to 30 W under load also changed nothing. The MMIO copy
never moves at all. `MSR 0x64F` reports `PL1` as the limiter throughout,
whatever the registers say. The enforcing agent is below both, most plausibly an
EC-side limit applied over PECI, which no OS interface reaches.

#### The OMEN handshake does not unlock it

Tested with `hp_wmi` unloaded so nothing could interfere: `0x1A`+`0x27`+`0x10`
on entry, performance confirmed at PL1=90 W, then `0x1A`+`0x27`+`0x23` re-sent
**every 2 seconds** for 60 s under load. Result **44.3 W** against a 44.9 W
control. The "take-control heartbeat" theory from `../FINDINGS.md` §4 is tested
and rejected. Also settled: the 2-byte and 4-byte `0x1A` forms are equivalent,
closing the open question in `../hp-wmi-8603.md`.

Every row above was measured 20+ minutes after boot with no heartbeat running, i.e.
with the EC already latched. The conclusions drawn from them at the time ("45 W by
design", "the MSR is inert", "the handshake does nothing") were correct descriptions
of a latched EC and wrong about the machine.

This directory is new work; it does not modify anything in the parent directory.
See `docs/CORRECTIONS.md` for how it revises the original `../FINDINGS.md`.

---

## Why the stock driver does nothing here

Board `8603` **is** already in `omen_thermal_profile_boards[]` upstream — the
patch proposed in `../hp-wmi-8603.md` has been merged since that document was
written, and is no longer needed. Two *other* bugs kept the interface dead:

### 1. `platform_profile_omen_get_ec()` rejects this board's EC byte

`hp-wmi` seeds the profile by reading EC offset `0x95` and accepts only
`0x00/0x01/0x02` (v0) or `0x30/0x31/0x50` (v1). On board 8603 that offset is
not the thermal profile byte at all — it sits inside an ASCII string:

```
00000090  33 33 33 2d 31 37 2d 35  35 53 52 30 xx xx xx xx  |333-17-55SR0xxxx|
                          ^^ 0x95 = 0x37
```

So the read returned `-EINVAL`, `thermal_profile_setup()` bailed, and because
`hp_wmi_bios_setup()` discards that return value it failed **silently** — no
`platform_profile`, and nothing in `dmesg` to explain it.

`patches/0001` defaults to `balanced` on an unrecognised value instead of
giving up, mirroring what the driver already does for Victus S boards with an
unknown EC layout, and logs the setup failure if one happens anyway. This is
safe because `platform_profile_omen_get()` serves reads from the cached
`active_platform_profile`, not from the EC.

### 2. The firmware echoes every profile write back as an Fn+P keypress

With bug 1 fixed the interface registers — and immediately becomes unusable.
The firmware answers each thermal-profile WMI write with an
`HPWMI_FN_P_HOTKEY` notification, which `hp_wmi_notify()` turns into
`platform_profile_cycle()`, which issues another write, which produces another
notification:

```
platform_profile_omen_get <-_aggregate_profiles
 => platform_profile_cycle
 => wmi_notify_device
 => acpi_wmi_notify_handler
 => acpi_ev_notify_dispatch
```

Measured at **~900 profile changes per second**, with a kworker pinned. Reading
the profile returned a different random value almost every time. Verified as
self-inflicted: 824 notifications in 4 s with the profile registered, **0** with
the stock driver or with `hp_wmi` unloaded.

`patches/0002` timestamps driver-initiated writes and ignores Fn+P
notifications arriving within 300 ms of one. The physical Fn+P key still
cycles profiles.

### 3. Nothing fed the EC's host-alive watchdog

With 1 and 2 fixed the mode reached the EC, but the EC clamps the package to 45 W
in every mode once EC[0x29] bit 7 (OCCN) has been clear for ~6 minutes, and only a
reboot releases it. The stock driver sends `0x10` exactly once on Victus S boards
and never on OMEN boards. `patches/0003` adds a `delayed_work` that sends `0x10`
(sets OCCN) and `0x23` (IR sensor read, which OMEN polls every 30 s) every
`omen_host_alive_secs` seconds (default 30) on boards listed in
`omen_occ_boards[]`, starting from `hp_wmi_bios_setup()`; it also switches the
profile *read* for those boards to `EC[0x29] & 3`, which is where the mode really
is, so the "Unknown EC thermal profile value 0x37" warning from patch 0001 no
longer fires here.

---

## Install

```bash
cd omen8603-linux
sudo ./install.sh
```

That copies the patched source to `/usr/src/hp-wmi-8603-1.0`, registers it with
DKMS and installs it to `/usr/lib/modules/$(uname -r)/updates/dkms/`, which
takes precedence over the in-tree module (`search updates extramodules built-in`).
DKMS rebuilds it automatically on kernel upgrades.

Verify:

```bash
./tools/omen-verify
```

Secure Boot is off on this machine, so DKMS module signing is not a concern.
If you ever enable it, enrol `/var/lib/dkms/mok.pub` with `mokutil`.

## Uninstall

```bash
sudo ./uninstall.sh
```

DKMS restores the archived in-tree module and runs `depmod`.

---

## Using it

`power-profiles-daemon` picks the driver up automatically and now reports a
real platform driver rather than `placeholder`:

```bash
powerprofilesctl set performance
powerprofilesctl set balanced
```

Each write reaches the EC within a quarter second (verified by tracing EC[0x29]:
`0x80` balanced, `0x82` cool, `0x81` performance), and `omen-power` follows it
with the RAPL limits within about a second. Sustained power in performance is
expected to be ~77 W once the machine has booted with the heartbeat in place.

Or write it directly:

```bash
echo performance | sudo tee /sys/class/platform-profile/platform-profile-0/profile
```

The legacy `/sys/firmware/acpi/platform_profile` path also works. If you do not
run `power-profiles-daemon` and want performance asserted at every boot, enable
the optional unit:

```bash
sudo cp systemd/omen-profile.service /etc/systemd/system/
sudo systemctl enable --now omen-profile.service
```

Max fan is exposed separately by the same driver and does **not** need any
patch — it works with the stock module too:

```bash
echo 0 | sudo tee /sys/class/hwmon/hwmon6/pwm1_enable   # 0 = max fan, 2 = auto
```

`fan1_input`/`fan2_input` exist but read 0 RPM: this board reports no fan
tachometer over WMI. That is a firmware limitation, not a driver bug.

---

## Layout

```
src/        patched hp-wmi.c (+ .orig), Makefile, dkms.conf
patches/    the three changes as standalone diffs, against v7.1.9 (apply in order)
tools/      omen-verify (health check), omen-measure (A/B/A power benchmark),
            omen-power (RAPL follower daemon + status/watch)
lab/        omen-wmi-lab - read-only WMI/MCHBAR investigation module, and the
            record of what it ruled out (see lab/README.md)
systemd/    omen-power.service (installed by install.sh), optional omen-profile.service
docs/       CORRECTIONS.md — what this revises in ../FINDINGS.md
            UPSTREAM.md    — notes for submitting these patches
```

## Kernel version

Built and verified against **7.1.9-arch1-2**. `src/hp-wmi.c.orig` is the
unmodified `drivers/platform/x86/hp/hp-wmi.c` from **v7.1.9**. On a future
kernel, refresh it and reapply `patches/*.patch`:

```bash
curl -sSL 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/platform/x86/hp/hp-wmi.c?h=vX.Y.Z' -o src/hp-wmi.c.orig
cp src/hp-wmi.c.orig src/hp-wmi.c
for p in patches/*.patch; do patch -p5 -d src < "$p"; done
```
