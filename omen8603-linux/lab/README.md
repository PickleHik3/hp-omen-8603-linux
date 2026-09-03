# omen-wmi-lab — investigation tool (read-only)

An out-of-tree module for issuing arbitrary HP BIOS WMI commands and reading
MCHBAR registers on OMEN board 8603. It exists because `hp-wmi` only ever sends
the thermal-profile command (`0x1A`), and the questions raised by
`../../FINDINGS.md` needed the rest of OMEN's captured call sequence.

**It has no write paths beyond the WMI commands OMEN itself sends.** The MCHBAR
interface is read-only by construction and confined to the MCHBAR window; there
is deliberately no MMIO write, because the investigation showed one would be
pointless (see below).

```bash
make && sudo insmod omen-wmi-lab.ko

# WMI: <command> <commandtype> <outsize> <hex input>
echo '0x20008 0x28 8 0000000000000000' > /sys/kernel/debug/omen-wmi/call
cat /sys/kernel/debug/omen-wmi/result        # -> 4a 01 38 00 ...

# MCHBAR read: <address>
echo 0xfed159a0 > /sys/kernel/debug/omen-wmi/mmio_read
cat /sys/kernel/debug/omen-wmi/result
```

## Validated against the Windows trace

| command | result | matches `FINDINGS.md` |
|---|---|---|
| `0x28` system design data | `4a 01 38 00` | yes, exactly |
| `0x10` post-mode-change | `02 00 00 00` | yes, "returned `0x02`" |
| `0x23` poll | `0x20` (32) | yes, small drifting integer |
| `0x26` / `0x11` | `rc=0`, zeros | yes |

## What it established

- The 2-byte `[FF,mode]` form `hp-wmi` sends and the 4-byte `[FF,mode,0,0]`
  form OMEN sends are **equivalent** - both set `MSR 0x610` PL1 to 90 W.
- The full OMEN sequence, re-sent every 2 s under load, does **not** raise
  sustained power: 44.3 W against a 44.9 W control.
- `PACKAGE_RAPL_LIMIT` at MCHBAR+0x59A0 reads PL1 = 90 W in *every* profile and
  never changes, so the `SyncMMIO` theory is dead and an MMIO write would
  achieve nothing.

## Caution

Issuing a `0x1A` from here while the patched `hp-wmi` is loaded will trip the
firmware's Fn+P echo. The driver's echo guard only suppresses echoes from its
*own* writes, so the profile gets cycled out from under you - which invalidated
one of these experiments before it was spotted. Unload `hp_wmi` first.
