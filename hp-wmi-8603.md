# The verified protocol, and the `hp-wmi` patch

Everything here was captured live from OMEN Gaming Hub's own call trace
(`…\LocalCache\Local\HPOMEN\HPOMENBG_*.log` logs every BIOS WMI call with full
arguments), then independently re-issued from an external WMI caller and
confirmed to return `rc=0`.

## The wire protocol

All calls go through `hpqBIntM` / `WMAA`, GUID `{5FB7F034-2C63-45E9-BE91-3D44E2C707E4}` —
the same interface `hp-wmi` binds to.

```
Sign        = "SECU"  (0x53 0x45 0x43 0x55, i.e. signature 0x55434553)
Command     = 131080  = 0x20008   (HPWMI_GM, the OMEN gaming-mode channel)
```

### Set thermal mode — `CommandType = 26 (0x1A)`, 4 bytes in

```
inputData = [0xFF, <mode>, 0x00, 0x00]
```

| OMEN UI button | internal name | `<mode>` | captured inputData |
|---|---|---|---|
| Performance | `Performance` | **0x01** | `255,1,0,0` |
| Balanced / Default | `Default` | **0x00** | `255,0,0,0` |
| Comfort | `Cool` | **0x02** | `255,2,0,0` |
| **Eco** | `Eco` | **0x00** | `255,0,0,0` |

**Note the surprise: Eco and Balanced send the identical firmware value.** The EC
only has three thermal states. "Eco" is a pure Windows-side construct (power plan
+ OMEN's own throttling), not a firmware mode. So on Linux you have exactly three
profiles to expose, which maps cleanly onto `platform_profile`'s
`cool` / `balanced` / `performance`.

These values match upstream `hp-wmi`'s `enum hp_thermal_profile_omen_v0`
(`DEFAULT=0x00`, `PERFORMANCE=0x01`, `COOL=0x02`) exactly.

### Max fan — `CommandType = 39 (0x27)`, 1 byte in

```
inputData = [0x01]   -> max fan ON
inputData = [0x00]   -> max fan OFF
```

Matches `HPWMI_FAN_SPEED_MAX_SET_QUERY`. Independent of thermal mode — OMEN
sends 0x1A and 0x27 as a pair on every mode change.

### Other commands seen in the trace

| CommandType | in | notes |
|---|---|---|
| `0x23` (35) | 4 B zeros | polled every 30 s — the heartbeat. `rc=0` |
| `0x10` (16) | 4 B zeros | issued after a mode change. `rc=0` |
| `0x11` (17) | 4 B | fan speed get. `rc=0` |
| `0x26` (38) | 4 B | max fan get. `rc=0` |
| `0x28` (40) | — | system design data. `rc=0`, returns `4A 01 38 00` |
| `0x22` (34) | 1 B | tried once after switching to Performance — **`rc=3`, unsupported** |

## Verification I ran

Re-asserting the already-active mode from a standalone WMI caller (idempotent,
no state change):

```
cmd=0x20008 t=0x1A data=[255,1,0,0]  -> rc=0
cmd=0x20008 t=0x23 data=[0,0,0,0]    -> rc=0
cmd=0x20008 t=0x10 data=[0,0,0,0]    -> rc=0
```

So the command is not privileged to HP's own drivers. Any WMI caller — including
a patched `hp-wmi` — can drive it. `evidence/hp-bios-wmi-probe.ps1` reproduces this.

## The patch

In `drivers/platform/x86/hp/hp-wmi.c`, add `"8603"` to the OMEN board allowlist.
`8600`, `8601`, `8602`, `8605`, `8606`, `8607` are already there — `8603` looks
like a plain omission for this SKU. Grep your own tree rather than trusting a
snippet, since the array names drift between versions:

```bash
grep -n '8607' drivers/platform/x86/hp/hp-wmi.c
```

Start with `omen_thermal_profile_boards[]` only; leave the `_force_v0_` and
`_timed_` variants alone unless the first doesn't take.

### One thing to check carefully — the buffer shape

This is the most likely reason a naive patch still fails, so verify it before
concluding the board ID was wrong.

Upstream `omen_thermal_profile_set()` builds something along the lines of
`char buffer[2] = {0, mode}` and passes `sizeof(buffer)` — a **2-byte** payload
whose first byte is **0x00**.

OMEN itself sends **4 bytes** with a leading **0xFF**: `[0xFF, mode, 0x00, 0x00]`.

I did not test whether the 2-byte `{0x00, mode}` form is accepted by BIOS F.53 —
I only confirmed the 4-byte `0xFF`-prefixed form returns `rc=0`. If your patched
driver registers `platform_profile` but writes appear to do nothing, make the
driver send the 4-byte form and retest. That single detail may be the whole
difference.

### How to verify it took

```bash
dmesg | grep -i hp_wmi
cat /sys/firmware/acpi/platform_profile_choices    # expect: cool balanced performance
echo performance | sudo tee /sys/firmware/acpi/platform_profile
sudo ./ec-calibrate performance                    # EC[0x95] should read 0x01
```

`hp-wmi` reads the current profile with `ec_read(0x95)`, and your DSDT declares
the EC properly (`Device(EC0)`, `_HID=PNP0C09`, `_CRS = IO 0x62 / IO 0x66`), so
the get side should work. The set side is the WMI call above.

## Why this is now the complete fix

Measured (see `FINDINGS.md` §3): the 45 → 90 W ramp is performed by EC/BIOS
firmware on its own. OMEN wrote **zero** bytes to PL1 during a 90-second all-core
load that held 3.89 GHz. So setting the mode is genuinely all that's required —
no power-limit daemon, no MSR writes, no fan curve to reimplement.

## Upstreaming

A board-ID addition with `dmesg` plus `platform_profile` output as evidence is
about the easiest patch to land in `platform-driver-x86@vger.kernel.org`, and it
fixes this for every other 17-cb0 owner. If the 4-byte buffer difference turns
out to be real, that's a more interesting patch and worth reporting either way.
