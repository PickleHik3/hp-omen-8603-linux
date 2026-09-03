# OMEN 17-cb0xxx ("Santorini") — Linux performance-profile investigation

> **Superseded in part (2026-09-03).** Windows-side ring-0 measurements in `FINDINGS-2026-09-03-windows.md`
> show §3 below is wrong (OMEN does ramp PL1 itself), the mode byte is EC[0x29] bits 1:0 (not 0x95), and the
> 44.8 W seen on Linux is an EC clamp that latches ~6 min after the OMEN heartbeat stops. Read that file first.

All facts below were measured on this machine.

> **Revision note.** An earlier draft concluded the 45 → 90 W ramp was a userspace
> MSR 0x610 control loop inside OMEN Gaming Hub. **That was wrong**, and the
> correction is in your favour — see §3. The strings that suggested it are real,
> but they belong to a code path this platform has disabled.

## Machine identity

| Item | Value |
|---|---|
| Model | OMEN by HP Laptop 17-cb0xxx |
| **Board ID (DMI_BOARD_NAME)** | **`8603`** |
| BIOS | AMI `F.53` (2024-04-24) |
| CPU | i7-9750H (6C/12T, Coffee Lake-H, 45 W base) |
| Codename | **Santorini** (`…PowerControl.JSON.Santorini10.json`) |
| OMEN Gaming Hub | `1101.2607.3.0` |

## 1. Why `hp-wmi` gives you no `platform_profile`

I called HP's BIOS WMI interface (`hpqBIntM`, GUID `{5FB7F034-…}` — the one
`hp-wmi` binds to) with the same `bios_args` layout `hp_wmi_perform_query()`
uses. Read-only results:

| Query | cmd | type | rc |
|---|---|---|---|
| `HPWMI_FEATURE2_QUERY` | 0x01 | 0x0D | **0x00 works** |
| `HPWMI_HARDWARE_QUERY` | 0x01 | 0x04 | **0x00 works** |
| **`HPWMI_THERMAL_PROFILE_QUERY`** | 0x01 | **0x4C** | **0x04 unsupported** |
| `HPWMI_FAN_SPEED_GET` | 0x20008 | 0x11 | **0x00 works** |
| `HPWMI_FAN_SPEED_MAX_GET` | 0x20008 | 0x26 | **0x00 works** |
| `HPWMI_GET_SYSTEM_DESIGN_DATA` | 0x20008 | 0x28 | **0x00 works** |

1. **The generic HP thermal-profile command (0x4C) does not exist in this BIOS.**
   0x04 at every buffer size. That logic lives in the **SMM handler, not AML** —
   which is why importing or patching the DSDT could never work. There was no
   ACPI code to fix. Stop pursuing that route.

2. **The OMEN gaming-mode channel (`HPWMI_GM = 0x20008`) is fully alive.**

`hp-wmi` chooses between these by matching `DMI_BOARD_NAME` against a hardcoded
allowlist. **Board `8603` is not in it** (`8600`–`8607` are otherwise present).
So the driver takes the generic branch, gets 0x04, registers nothing. Your EC is
not broken and never was.

## 2. What the platform actually supports

OMEN Gaming Hub logs its capability probe at startup
(`…\LocalCache\Local\HPOMEN\HPOMENBG_*.log`). For this machine:

```
IsBiosPerformanceModeSupport    = True     <-- BIOS performance-mode command EXISTS
IsBiosCoolModeSupported         = True
IsMaxFanSupported               = True     <-- matches WMI probe 0x26 rc=0x00
IsPowerControlSupported         = True
IsDynamicPowerLimitSupport      = False    <-- userspace PL1 algorithm DISABLED
IsSwFanControlSupport           = False
IsBiosPerformanceControlSupport = False
IsSurfaceTempSupport            = False
IsVrSensorSupport               = False
IsUnleashedModeSupport          = False
IsExtremeModeSupport            = False
IsTppSupport / IsIccMaxSupport  = False
```

## 3. The correction: the EC does the ramp, not software

`HP.Omen.Background.PerformanceControl.dll` really does contain
`AlgoPowerControlDynamic()`, `SetPowerLimitByMsr`, `MSR 0x610 is PL1 [{0}] PL2 [{1}]`,
`RunHeartbeatLoop` and the IR-sensor step logic. But that DLL serves all 155
platforms, and **`IsDynamicPowerLimitSupport = False` means Santorini never runs
it.** `Santorini10.json`'s `"Increase": 5` / `"IntervalAlgoShort": 1000` are
inert defaults for a disabled code path — I over-read them.

Measured proof. A 90-second all-core load (12 threads):

- Effective clock held **3.74 → 3.89 GHz all-core**, still climbing at the end.
  That is far above a 45 W budget on a 9750H — the ramp is real and observable.
- `Pl1Clip_*.log` delta: **0 bytes**
- `FanSpeed_*.log` delta: **0 bytes**
- `HPOMENBG` delta: 80 KB, **entirely foreground-app tracking**, zero power lines

**OMEN Gaming Hub wrote nothing while the CPU ramped.** So the 45 → 90 W stepping
you see on Windows is done autonomously by **EC/BIOS firmware**, once the
performance mode has been set.

### Why this is good news

You do **not** need a PL1 daemon on Linux. You need to set one mode, once. The
firmware handles the rest — the same ramp, the same fan curve, the same 90 W
ceiling. This makes the fix far simpler and far more robust than a userspace
loop fighting the EC.

Your "flip an EC value every 20 s" experiment worked because you were re-asserting
the *mode*, which the EC reverts when nothing owns it — not because you were
manually driving power limits.

## 4. About the "switch that flips when OMEN Hub + drivers are installed"

You were right that something changes. Installed and running on this machine:

| Component | Role |
|---|---|
| `HPOmenCap` (service) | "HP Omen HSA Service" — backs `OmenHsaClient` / `BiosWmiCmd_Get/Set` |
| `HpReadHWData.sys` | ring-0 MSR read/write driver |
| `uiomap.sys` | direct port-I/O mapping driver |
| `HPOmenCustomCapDriver.sys`, `HPCustomCapDriver.sys` | HP custom capability drivers |

And the behaviour that most likely produced what you saw:

```
07:16:58  Entry::RestoreStorageSettings - Mode = Performance, MaxFan = Off, ThermalMode = Auto
18:37:52  Entry::RestoreStorageSettings - Mode = Performance, MaxFan = Off, ThermalMode = Auto
18:38:23  ...UpdateProfileTimestamp ... PerformanceControl\MaxFan
```

**OMEN re-applies the saved mode at every boot and every logon.** With the stack
installed, the mode byte is set and kept set. Uninstall it and nothing asserts
it, so it reads back at the firmware default. That is very probably your
"switch" — the profile byte itself, not a separate enable bit.

**Is it a dealbreaker? No.** Two reasons:

1. Whatever that byte is, `ec_sys` can write it from Linux. Nothing about it is
   privileged to HP's drivers.
2. We don't have to guess. `ec-calibrate --diff` finds it mechanically by
   diffing full 256-byte EC snapshots across modes.

I can't fully rule out a separate "software present / take control" bit — the
log line `Heartbeat Start - Initial or User logon or OGH take-control` hints at
a handshake. But the EC diff settles it either way, and it costs one boot cycle
to find out. Treat this as the one open question, not a blocker.

## 5. The protocol, captured and verified

OMEN logs every BIOS WMI call with full arguments. Clicking through all four
modes produced the complete recipe (details in `hp-wmi-8603.md`):

```
Sign = "SECU"   Command = 0x20008   CommandType = 0x1A   4 bytes
inputData = [0xFF, <mode>, 0x00, 0x00]

    Performance = 0x01      Balanced/Default = 0x00      Comfort/Cool = 0x02
    Eco         = 0x00      <-- identical to Balanced; only 3 firmware states exist

Max fan:  CommandType = 0x27, 1 byte, [0x01] on / [0x00] off
```

I then re-issued the performance-mode call from a standalone WMI caller and got
**`rc=0`** — so the command is not privileged to HP's drivers, and a patched
`hp-wmi` can drive it.

### Proven end to end with the HP stack shut down

All OMEN/HP processes killed and all five HP services stopped, so the *only*
thing setting the profile was the raw WMI call. A/B/A, 12-thread load, sustained
all-core clock over the last 20 s of each 60 s measurement window:

| Phase | command | sustained clock | % of 2.6 GHz base |
|---|---|---|---|
| DEFAULT-1 | `[255,0,0,0]` | 3.01 GHz | 115.9 % |
| **PERFORMANCE** | `[255,1,0,0]` | **3.59 GHz** | **138.1 %** |
| DEFAULT-2 | `[255,0,0,0]` | 2.99 GHz | 115.1 % |

**Delta: +0.59 GHz, +19.6 % sustained clock.** All four calls returned `rc=0`.

The two DEFAULT runs bracket PERFORMANCE and agree to within 0.02 GHz, so this
is not drift. OMEN's log was last written at 19:05:37 and its last mode command
was at 18:55:54 — nothing in the HP stack touched the profile during the
19:16–19:25 test window.

**One WMI command, no HP software, ~20 % more sustained clock.** That is the
whole mechanism, confirmed.

Caveat on cross-test comparison: an earlier run measured 3.83–3.89 GHz in
performance mode, higher than the 3.59 GHz here. Those used different load
generators (`yes` vs a floating-point multiply loop); an FP loop draws more power
per clock, so it settles lower at the same wattage. The numbers are not
comparable across harnesses — only the within-harness A/B/A above is.

## 5b. Fan control: there is nothing beyond the max-fan toggle

Checked directly. On this platform there is no fan control or fan telemetry of
any kind other than the on/off max-fan boost:

| Check | Result |
|---|---|
| `IsSwFanControlSupport` | **False** — no software fan curve |
| `IsBiosPerformanceControlSupport` | **False** |
| `HPWMI_FAN_SPEED_GET` (0x11) | `rc=0` but **returns all zeros**, idle and under sustained load |
| OMEN's own `FanSpeed_*.log` | contains only `log Start` lines — never records a speed |
| **`PNP0C0B` (ACPI Fan) objects in DSDT** | **zero** |
| `IsMaxFanSupported` / 0x26 / 0x27 | **True / works** |

`CurrentLegacyFanMode` / `SetLegacyFanModeFromOverlay` sound promising but are
just the UI's `Normal` vs `Max` label for that same toggle — the overlay logs
`LegacyFanModeUpdateToOverlay, mode = Normal` alongside `ThermalControl = Auto`
or `Max`.

**Consequences for Linux:**

- Because the DSDT declares **no `PNP0C0B` fan devices**, Linux will not create
  ACPI fan objects. You get no fan nodes for free — not from `thermal`, not from
  ACPI. Don't waste time looking for them.
- Fan RPM is not readable over WMI here, so a patched `hp-wmi` will give you the
  max-fan switch but no meaningful `fan1_input`.
- The fan *curve* is entirely EC-side and is selected by the thermal mode. That
  is a feature, not a limitation: picking `performance` gets you HP's own tuned
  curve without reimplementing one.
- If you later want real RPM readout or a custom curve, the only route is raw EC
  registers (NBFC-style). `ec-calibrate --diff` will find them — snapshot with
  max-fan off, then on, and diff.

Also mapped: `commandType 0x23`, the 30 s poll, returns a slowly-drifting small
integer (38 then 37, unchanged across a 48 s all-core load). That is a skin /
chassis temperature, not CPU temp — consistent with `IrSensorThreshold: 56` in
`Santorini10.json`. `commandType 0x10` returned `0x02`.

## 5c. ThrottleStop, and the one number still missing

`C:\ThrottleStop_9.7\ThrottleStop.ini` decoded (power units 0.125 W, value / 8 = W):

| Profile | PL1 | PL2 | raw EAX / EDX |
|---|---|---|---|
| **0 `Default` (active, `Profile=0`)** | **90 W** | **90 W** | `0x00DD82D0` / `0x004282D0` |
| 1 `Game` | 90 W | 90 W | same |
| 2 `Internet` | 75 W | 90 W | `0x00DD8258` |
| 3 `Battery` | 75 W | 90 W | same |

`0x82D0 & 0x7FFF = 720 -> 90 W`, enable bit set, clamp set, PL1 time window ~28 s,
PL2 window ~2.4 ms. Also: `PowerLimit4 = 0x518` = **163 W**; `IccMax` 140 A;
`LockPowerLimits=0`; `MSRLock=0x0`; a ~-115 mV core/cache undervolt that does not
actually apply on this machine because virtualization is enabled.

Two keys worth knowing:

- **`NoSetPL=0xC`** — per-profile bitmask of "do not set power limits". Bits 2,3
  set means *Internet* and *Battery* skip it; profiles 0 and 1 **do** apply 90 W.
- **`SyncMMIO=0x3`** — profiles 0 and 1 write the **MMIO** copy of the limit too.
  Independent confirmation that on this platform setting only the MSR is not
  enough. Exactly the `intel-rapl` vs `intel-rapl-mmio` trap in §3.

**Still unmeasured: actual package watts per mode.** The `.ini` holds settings,
not measurements; `LogFileDirectory` pointed at a directory that did not exist,
so ThrottleStop had never logged. Attempts to get it to log headlessly failed —
adding `LogFile=1` produced nothing, and its window is a collapsed 160x28 tray
bar with no visible client area to read. Windows' own `\Power Meter` counters
return 0 on this machine, and no other ring-0 monitor is installed.

So the open question is **whether firmware performance mode reaches 90 W by
itself**, or tops out lower with ThrottleStop supplying the rest. Note the A/B/A
in §5 ran with ThrottleStop *not* active (task Disabled, exe not running,
`NoSetPL` bit clear only for a profile that was never applied) — so that
+19.6 % is firmware alone, whatever its ceiling.

`measure-power` answers this on Linux in about five minutes, using the RAPL
energy counter (`intel-rapl:0/energy_uj`) — the same MSR 0x610 domain
ThrottleStop reads, but exposed as a plain sysfs file.

## 6. What to do, in priority order

**Primary — patch `hp-wmi` to add board 8603.** See `hp-wmi-8603.md`. This is now
the *complete* fix, not an optional extra, because the firmware does the ramp.
Read the note there about the 4-byte `0xFF`-prefixed buffer — upstream may send a
2-byte form, and that detail could be the difference between working and not.

**Fallback — write the EC byte directly.** If the kernel route stalls, `omen-perf`
sets and re-asserts the mode byte from userspace with no kernel changes.

**Not needed — the PL1 daemon.** `omen-perf` still has an opt-in RAPL ramp
(`ENABLE_PL1_RAMP=1`), but on this platform it should be unnecessary and is off
by default. Only reach for it if the EC mode alone doesn't deliver 90 W.

## 7. Files here

- `history/ec-calibrate` — read-only EC snapshot/diff tool. **Run this first.**
- `history/omen-perf` — sets + re-asserts the EC mode byte; optional PL1 ramp.
- `history/omen-perf.service` — systemd unit.
- `hp-wmi-8603.md` — the kernel patch route (now the primary fix).
- `evidence/` — DSDT, the WMI probe scripts, and the 2026-09-03 Windows logs and tools. HP's `Santorini10.json` is not redistributed; the values that matter are quoted in §3.
