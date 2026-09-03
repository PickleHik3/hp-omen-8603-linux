# What this revises in `../../FINDINGS.md`

> **Addendum, 2026-09-03 (evening).** Everything below that concludes the machine
> is capped at 45 W was measured on a *latched* EC. Windows-side ring-0 work the
> same day (`../../FINDINGS-2026-09-03-windows.md`, artifact *The EC Latch*) showed
> that the EC clamps the package to 45 W in every mode once the host-alive bit
> EC[0x29].7 (OCCN, set by WMI 0x20008/0x10) has been clear for ~6 minutes, and
> that only a reboot releases the clamp. Every Linux run here started 20+ minutes
> after boot with nothing sending 0x10, so every one of them measured the latch.
> Specifically superseded: "this is a 45 W-sustained machine by design", "the PL1
> daemon cannot work", "the take-control handshake is rejected" (it was replayed on
> a latched EC, where nothing works), and "the MSR is inert" (it is inert *while
> latched*; unlatched, the CPU runs at min(MSR, EC)). Still correct: the two driver
> bugs, the protocol, the fan findings, and the 0x95-is-a-serial-string finding,
> now resolved by reading EC[0x29] & 3 (patch 0003). The fix is patch 0003's
> kernel heartbeat plus `omen-power`; see `../README.md`.

The original investigation was done on Windows 11 in August 2025. Everything
below was re-measured on Arch Linux, kernel **7.1.9-arch1-2**, on 2026-08-28,
on the same machine (board 8603, BIOS F.53, i7-9750H). The original file is
left untouched.

## Still correct

- Machine identity, and §5's captured protocol: `cmd 0x20008`, `commandType
  0x1A`, `Performance = 0x01 / Default = 0x00 / Cool = 0x02`. The in-tree driver
  sends exactly this, and it works.
- §3's conclusion that the ramp is firmware-side, not a userspace PL1 loop.
  Confirmed from the other direction: see "the mechanism" below.
- §5b's fan findings: no `PNP0C0B` objects in the live tables, no fan tach over
  WMI (`fan1_input`/`fan2_input` read 0 RPM even at 88 W under load).

## Superseded

### §1 and §6 — "patch hp-wmi to add board 8603"

Already merged upstream. `8603` is present in `omen_thermal_profile_boards[]`
in 7.1.9 (verified by resolving the array's relocations out of the shipped
module, not by string matching):

```
8600 8601 8602 8603 8604 8605 8606 8607 860A ...
```

It is *not* in `omen_thermal_profile_force_v0_boards[]` (`8607 8746 8747 8748
8749 874A`) or `omen_timed_thermal_profile_boards[]` (`8A15 8A42 8BAD`), which
is correct — see below.

### `hp-wmi-8603.md` — "the 4-byte vs 2-byte buffer may be the whole difference"

It is not. The current driver sends `[0xFF, mode]`, 2 bytes — the `0xFF` prefix
is already there, only the length differs from OMEN's 4 bytes, and 2 bytes is
accepted. The driver also chooses the v0 (`0x00/0x01/0x02`) vs v1
(`0x30/0x31/0x50`) encoding at runtime from **byte 3 of the `0x28`
system-design-data reply**. The recorded reply `4A 01 38 00` gives byte 3 = 0,
so it selects v0 — matching the OMEN trace exactly.

### §6 fallback and `omen-perf` — "write the EC byte directly"

**Do not run `../omen-perf` as written.** EC offset `0x95` is not the thermal
profile byte on this board; it is inside an ASCII string:

```
00000090  33 33 33 2d 31 37 2d 35  35 53 52 30 xx xx xx xx  |333-17-55SR0xxxx|
                          ^^ 0x95 = 0x37 = '7'
```

`omen-perf` would write `0x01` there and `0x00` on exit, corrupting a byte of
EC RAM to no effect. The whole EC-write route is unnecessary now that the WMI
route works.

### §6 / `ec-calibrate` — the calibration procedure

Steps 1–3 are "boot Windows, pick a mode in OMEN Gaming Hub, reboot into
Linux". Windows is gone, so this is no longer executable — and the anchor it
documents (`0x95`) is wrong anyway. Superseded entirely: the profile is now
settable from Linux.

### §6 / §5c — "the PL1 daemon"

Not just unnecessary, it **cannot work**. Before any profile was set, `MSR
0x610` already read PL1 = 90 W, unlocked, with turbo on, `max_perf_pct=100`,
`EPP=performance` and 39 °C of thermal headroom — and the CPU still delivered
44.9 W at 2.7 GHz, reporting **PL1** as the active limit reason in `MSR 0x64F`.
Writing PL1 from Linux changes nothing; the mode command is what matters.

Also: there is no `intel-rapl-mmio` zone and no `00:04.0` processor-thermal
device on this machine, so §5c's `SyncMMIO` / MMIO-trap concern does not apply
under Linux. There is only `intel-rapl:0`.

### §5b — "a patched hp-wmi will give you the max-fan switch"

You already had it. The hwmon half of `hp-wmi` does not depend on the
thermal-profile board list, so `/sys/class/hwmon/hwmon6/pwm1_enable` (0 = max
fan, 2 = auto) works with the stock module.

## §5c's open question, answered: no

> "whether firmware performance mode reaches 90 W by itself, or tops out lower
> with ThrottleStop supplying the rest"

**Under Linux it does not reach 90 W at all.** 60 s of 12-thread load per phase,
1 s sampling, each profile measured twice, process table verified clean before
and after every phase:

| | boost (first ~15 s) | sustained (last 20 s) |
|---|---|---|
| performance #1 | ~68 W @ 4.00 GHz | 44.7 W |
| performance #2 | ~67 W @ 4.00 GHz | 44.8 W |
| balanced | ~68 W @ 4.00 GHz | 44.8 W |

The two performance runs agree to 0.1 W; performance minus balanced is -0.1 W.

Both profiles do the same thing: full 4.00 GHz all-core for 13-16 s, limited by
the turbo **ratio** (`MSR 0x64F` = `MaxTurbo`) rather than by power, then a hard
clamp to ~45 W with the limiter switching to `PL1`. This is the behaviour
observed directly with s-tui: it throttles at roughly 15 seconds.

### `MSR 0x610` is inert here

The profile does change the register - 45 W for cool/balanced, 90 W for
performance, instantly and verifiably - but the value does not affect delivered
power. Writing PL1 down to 30 W under load also changes nothing:

```
 21   69.3 W   70 C   PL1reg=30   MaxTurbo
 22   53.4 W   70 C   PL1reg=30   PL1
 23   44.6 W   61 C   PL1reg=30   PL1      <- 30 W requested, 45 W delivered
```

30 W, 45 W and 90 W in the register all deliver 44.8 W. The ceiling is enforced
below the architectural MSR, by the EC or the PCU, and neither `platform_profile`
nor RAPL reaches it.

Ruled out as the cause: temperature (59-72 C against a 100 C limit), turbo ratio
limits (`MSR 0x1AD` allows 40x all-core), OS-side capping (`no_turbo=0`,
`max_perf_pct=100`, EPP=performance), PSys (`MSR 0x65C` disabled), config TDP
(`MSR 0x64B`=0, nominal 45 W level), and MMIO RAPL (no zone, no `00:04.0`
processor-thermal device).

### The remaining leads, both tested and rejected

**The take-control handshake.** `0x1A`(4-byte)+`0x27`+`0x10` on entry, then
`0x1A`+`0x27`+`0x23` re-sent every 2 s for 60 s under load, with `hp_wmi`
unloaded so nothing could cycle the profile: **44.3 W**, against a 44.9 W
control. Re-asserting `0x1A` alone every 3 s: 44.6 W. Neither helps.

**The MMIO copy (`SyncMMIO`).** `PACKAGE_RAPL_LIMIT` at MCHBAR+0x59A0 reads
PL1 = 90 W in *every* profile and never changes. So in performance mode both the
MSR and the MMIO copy say 90 W while the machine delivers 45 W. Writing the MMIO
copy cannot help.

### Superseded lead (kept for the record)

`../../FINDINGS.md` §5 records that OMEN sends `0x1A` **and `0x27` as a pair**
on every mode change, `0x10` immediately after, and polls `0x23` every 30 s -
which §4 flagged as a possible "OGH take-control" handshake. `hp-wmi` sends
**only `0x1A`**. That matches the symptom exactly: the mode registers, the PL1
register moves, but the budget is never released. Untested.

Supporting circumstantial evidence that the 90 W path exists at all: §5's
Windows A/B/A measured 3.59 GHz in performance against 3.01 GHz in default. No
Windows wattage was ever captured, so this is clock-based only.

### Where the retracted 88 W came from

The boost window itself. Measured from a cold start (43 C) the first seconds of
load draw **87.9 W**; from a warm start (51 C) the same window averages ~68 W.
So ~88 W is a real number this machine produces - for the first 13-20 seconds,
in *both* profiles, and then it clamps to 45 W regardless. Reporting it as a
sustained figure was the error. `tools/omen-measure` now refuses to run phases
shorter than 40 s for exactly this reason, and reports boost and steady state
as separate columns rather than one average.

### A retracted measurement

An earlier version of these notes reported 88.4 W sustained in performance mode
from a single 20 s window, and built a conclusion on it. It never reproduced as
a sustained figure; it was the boost window, which does reach ~88 W.
Worse, several of the follow-up runs that appeared to contradict it were
themselves invalid: a load generator from an earlier test had leaked and was
running 12 threads in the background throughout them. Everything in this
section comes from runs made after that process was killed, with explicit
before/after checks that the process table is clean.

## What the patches do and do not buy you

They **do** fix two genuine driver bugs (below) and give a correct, stable
`platform_profile` that `power-profiles-daemon` consumes. They **do not**
raise the sustained power ceiling on this machine.

## Two new bugs, both fixed here

1. `platform_profile_omen_get_ec()` returned `-EINVAL` for this board's
   `EC[0x95] = 0x37`, and `hp_wmi_bios_setup()` discards
   `thermal_profile_setup()`'s return value, so the feature was disabled
   silently with nothing logged.

2. The firmware echoes each thermal-profile write back as an
   `HPWMI_FN_P_HOTKEY` notification, which the driver turns into
   `platform_profile_cycle()` — a feedback loop running at ~900 profile changes
   per second. Measured 824 notifications in 4 s with the profile registered,
   0 with the stock driver.

See `../README.md` and `../patches/`.
