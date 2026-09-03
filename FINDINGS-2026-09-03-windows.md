# OMEN 17-cb0xxx (board 8603) — what actually gates the CPU power, measured from Windows

Date: 2026-09-03. Windows 11, BIOS F.53, OMEN Gaming Hub 1101.2608.1.0, i7-9750H, RTX 2080
(discrete-only: no Intel iGPU is enumerated, so the dGPU is always powered in both OSes).
All numbers below are measured on this machine with ring-0 access (PawnIO via LibreHardwareMonitorLib,
raw ACPI-EC port reads, HP's own WMI interface). Tooling and raw logs: `evidence/windows-2026-09-03/`.

This supersedes the conclusions of the Linux artifact "The 45 Watt Ceiling" and corrects `FINDINGS.md` §3.

## 1. The headline numbers

12-thread FP load, package power from the RAPL energy counter (MSR 0x611), averaged after the boost period.

| Condition | Sustained | All-core clock | MSR 0x610 PL1/PL2 |
|---|---|---|---|
| Performance, OMEN Gaming Hub running (as at logon) | **76.8–77.2 W** | 4.0 GHz (max turbo) | 90 / 90 |
| Balanced (WMI `0x1A [FF 00 00 00]`), OMEN running | **44.9 W** (clamp engages after ~25 s) | 3.2–3.3 GHz | 90 / 90 |
| Performance, OMEN killed ~5 min earlier | 77 W for ~80 s, then **44.8 W** for the rest | 4.0 → 3.1 GHz | 90 / 90 |
| Performance, OMEN dead, any WMI keepalive replayed (see §4) | **44.9 W** | 3.2 GHz | 90 / 90 |
| Performance, OMEN restarted after the clamp had engaged | **44.9 W** | 3.3 GHz | **55** / 90 |

So this is not a 45 W machine. Performance mode is worth +32 W sustained, and the previous Linux
measurement of 44.8 W "in every profile" was the clamp described below, not a design ceiling.

## 2. The register that the OS can see is not the one that governs

MSR 0x610 reads 90/90 W (enable+clamp set, tau 28 s) in every clamped state above, and 0x65C (platform
PL) is disabled. Linux additionally read the MMIO copy (MCHBAR 0xFED159A0) as 90 W. Yet the package
holds 44.9 W with PL1-style behaviour (a ~20–25 s boost budget, then a flat limit). The governing PL1
therefore comes from a third input that neither the MSR nor the MMIO mirror exposes. The only remaining
writer of package power limits on this platform is the **embedded controller over PECI**. That is also why
ThrottleStop cannot lift the limit in non-Performance modes, as you observed: the MSR it writes is not
the binding copy.

## 3. What the mode command really does (ACPI, decompiled from the live DSDT)

The OMEN WMI channel (`hpqBIntM`, command 0x20008) is dispatched by `\HWMC` to methods `GM01…GM30`:

| type | AML method | effect |
|---|---|---|
| 0x1A | `GM1A` | writes EC field **OCCM** (mode 0/1/2), then `WSMI(0x20008,0x1A,…)` = software SMI (port 0xB2 = 0xE4), then WMI event 0x1B |
| 0x10 | `GM10` | sets EC field **OCCN = 1**, returns 0x02 (this is OMEN's `GetNumOfFan()` heartbeat) |
| 0x23 | `GM23` | reads EC field **IRST** (IR/skin temperature; 34–35 °C during tests) |
| 0x26 / 0x27 | `GM26/27` | read / set max-fan (**MAXF**) |
| 0x11, 0x01, 0x02 | | return zeros (no fan RPM readout exists on this board) |
| 0x18, 0x19, 0x30 | | SMI-only "OC" commands, not used by OMEN here |
| 0x22, 0x29, 0x37 | | **not implemented** in this BIOS (rc=3): the BIOS "set power limit" paths OMEN has for other models |

EC RAM is memory-mapped at 0xFC7E0800 (`OperationRegion PECM/ECMM`); offsets 0x00–0xFF coincide with
the ACPI-EC index space that Linux `ec_sys` shows. Full field map: `evidence/windows-2026-09-03/acpi/ec-field-map.txt`.

**EC byte 0x29** is bit-packed: bits 1:0 = OCCM (mode), bit 6 = MAXF, bit 7 = OCCN. The Linux dumps
read 0x00/0x01/0x02 because OCCN was never set there; Windows reads 0x81 (performance + host alive).
OCCN is a watchdog: the EC clears it 60–75 s after it is set, and OMEN re-sets it every 90 s.
EC byte **0x95 is an ASCII digit of the serial string** ("333-17-55SR0xxxx"); the upstream `hp-wmi`
`omen_thermal_profile_get()` reads it, which is the real reason `platform_profile` never registered.

## 4. What does NOT release the clamp once it has engaged (all tested, OMEN dead)

- refreshing OCCN via WMI 0x10 every 60 s (E3a): 44.9 W
- writing EC[0x29] |= 0x80 directly (E3b): 44.9 W
- fresh 0x1A performance set + 0x23/30 s + 0x10/60 s (run A): 44.9 W
- re-sending 0x1A every 60 s + both keepalives (run D): 44.9 W
- writing OCCM=1 directly into EC[0x29] under a balanced-mode clamp (E4): 44.9 W
- restarting OMEN Gaming Hub (perf4): 44.9 W, and OMEN's own PL1 ramp stalled at 55 W

Every WMI command the previous Linux agent replayed was also replayed here, in the same latched state,
with the same null result. The clamp is a **latch**: it engaged about 6 minutes after the OMEN heartbeat
stopped, and nothing reachable from the OS released it. **A reboot cleared it** (verified 22:0x, see §4b).
The previous Linux agent always tested well after boot, so they only ever saw the latched state.

## 4b. After the reboot: the heartbeat prevents the latch (verified)

Fresh boot, OMEN alive: MSR PL1 = 45 W (OMEN's post-boot default) and the package sat at 44.9 W. Under a
150 s load OMEN's ramp was visible in the MSR column, 45 → 55 → 65 W, with package power tracking each step
(53 → 65 W). So with the EC unlatched the MSR is the binding limit, exactly as the model predicts.

Then OMEN was killed and only my keepalive ran (WMI 0x10 every 60 s, 0x23 every 30 s); ThrottleStop was
launched for ten seconds to put MSR PL1/PL2 at 90 W and killed again.

| Time after OMEN died | Load | Sustained |
|---|---|---|
| 1 min | 100 s | **77.1 W**, 4.0 GHz |
| 9–12 min | 200 s | **76.1–77.0 W**, 4.0 GHz, no droop |

Earlier the same day, the same state without a keepalive latched to 44.8 W within ~6 minutes (§1, row 3).
The host-alive heartbeat is therefore sufficient to keep the EC from clamping, provided it starts before the
latch engages. Log: `evidence/windows-2026-09-03/logs/boottest-after-reboot.log`.

## 5. What OMEN Gaming Hub actually does (decompiled, `HP.Omen.Background.PerformanceControl.dll`)

`FINDINGS.md` §3 said OMEN writes nothing to PL1 on this platform. That was wrong: its `DebugLog()` is an
empty method, so the PL1 writes never reach the log that conclusion was based on.

- `PowerControlFactory` → `AdaptivePowerControl` (NotebookV0). `Start()` logs "Algorithm goes with MSR".
- `MonitorThread()` → `AlgoPowerControlDynamic()`: every `IntervalAlgoShort` (1 s) in Performance mode,
  if package power ≥ 0.9 × PL1 it raises PL1 by 5 W (10 W if CPU <85 °C, 1 W if >90 °C) up to 90 W;
  IR-sensor and throttling handlers lower it. On mode change it resets PL1 to `PL1DefaultValueI5` = 45.
- Writes go through **HpReadHWData.sys** (IOCTL type 40001, function 2306): an 8-byte "index" with
  bit 63 set is a command — `0x8000_0200_0000_0000 | PL1×8` sets PL1, `…0300…` PL2, `…0800…` IccMax,
  `…0A00…` PL4, `…0100…` turbo on/off. Plain indexes read MSRs. The driver writes MSR 0x610 (the 55 W
  in perf4 is this ramp stalling because the PECI clamp keeps power below 0.9 × 55).
- Heartbeat: `GetNumOfFan()` = WMI 0x10 every `IntervalHeartbeat` (90 s here). The monitor thread also
  polls 0x23 (IR temp) and 0x21 (GPU status).

So on a healthy (unlatched) Windows session the picture is: EC releases PL1 in Performance mode while the
host heartbeat is alive; OMEN ramps the MSR copy 45 → 90 W; the CPU runs at min(MSR, EC) = up to 90 W
(77 W is simply what this load draws at 4.0 GHz all-core).

## 6. Consequences for Linux, in order

1. **The mode set is correct and already in mainline.** Current `hp-wmi.c` lists board 8603 and sends
   `{0xFF, mode}` on 0x20008/0x1A, exactly what OMEN sends. The two DKMS fixes the Linux agent made
   (profile-get via the wrong EC byte, Fn+P echo loop) are still needed: the get side should read
   `EC[0x29] & 3`, not `EC[0x95]`.
2. **Set Performance and start the heartbeat immediately at boot, before the latch engages.** The
   heartbeat is WMI 0x10 (sets OCCN) every ≤60 s; OMEN also polls 0x23 every 30 s. `omen-mode daemon`
   does this via `acpi_call` (`\_SB.WMID.WMAA 0 3 b<buf>`) or, as fallback, by writing EC[0x29] bit 7.
   Whether this alone prevents the latch is the one thing not yet proven: every test so far ran after the
   latch had engaged. `evidence/windows-2026-09-03/tools/boot-test.ps1` settles it in one reboot.
3. **Raise MSR PL1 to 90 W yourself** (`intel-rapl:0/constraint_0_power_limit_uw`, and the MMIO zone if
   present), since nothing on Linux plays OMEN's ramp. The SMM path does not do it (MSR stayed 90 across
   mode changes on Windows only because OMEN had ramped it earlier).
4. If Linux ever shows 44.8 W again with the daemon running, check `omen-mode status` first: OCCN must read 1
   and the daemon must have started within a few minutes of boot. A latched EC needs a reboot; the daemon
   cannot recover it (§4).

## 6b. Linux implementation (2026-09-03, evening)

Done in `omen8603-linux/`, superseding `omen-mode`, `omen-mode.service`, `omen-perf` and
the `acpi_call` route in this directory:

- **patch 0003** to the DKMS `hp-wmi`: on board 8603 the module itself sends WMI 0x10 + 0x23
  every 30 s from `hp_wmi_bios_setup()` (module parameter `omen_host_alive_secs`, 0 = off),
  fires one immediately on resume, and reads the profile from `EC[0x29] & 3`.
- **`omen-power.service`**: follows `platform_profile` via sysfs poll() and sets RAPL
  PL1/PL2 to 90/90 W in performance, 45/90 W otherwise (OMEN's MSR policy).
- Verified in-session on Linux: profile writes land in OCCM within 0.25 s (0x80/0x82/0x81),
  OCCN held at 1 for a 180 s trace with the 30 s heartbeat, RAPL follows within ~1 s.
  Sustained wattage not yet re-measured: that session was already latched (uptime 25 min at
  install; baseline load still 45 W), so §6.2's open question closes on the next boot with
  `sudo omen8603-linux/tools/omen-measure`.

## 7. Errata to earlier documents

- `FINDINGS.md` §3 ("EC does the ramp, OMEN writes nothing"): wrong, see §5.
- `FINDINGS.md` §6 / `omen-perf` default `EC_OFFSET=0x95`: wrong byte; the mode is EC[0x29] bits 1:0.
- Linux artifact "The 45 Watt Ceiling": the 44.8 W is the latched EC clamp, not the machine's design.
  MSR 0x64F on this box reads 0 through PawnIO for every register including ones that cannot be 0, so
  the Windows-side "no limit reason" column in the logs is a tooling artefact, not evidence.
