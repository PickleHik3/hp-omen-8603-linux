# Notes for sending these upstream

Both patches are in `../patches/`, against `v7.1.9`
`drivers/platform/x86/hp/hp-wmi.c`. List:
`platform-driver-x86@vger.kernel.org`, cc `linux-kernel@vger.kernel.org`.
Maintainers via `scripts/get_maintainer.pl`.

## 0001 — tolerate an unknown OMEN thermal-profile EC value

The stronger of the two, because it is a **silent** failure: a board that is on
`omen_thermal_profile_boards[]` gets `platform_profile` disabled with nothing in
`dmesg`, because `hp_wmi_bios_setup()` ignores `thermal_profile_setup()`'s
return value. The patch also adds the missing `dev_warn`.

Evidence to include:

```
$ cat /sys/class/dmi/id/board_name            -> 8603
$ cat /sys/class/dmi/id/bios_version          -> F.53
# EC dump, offsets 0x90-0x9f
00000090  33 33 33 2d 31 37 2d 35  35 53 52 30 xx xx xx xx  |333-17-55SR0xxxx|
# i.e. EC[0x95] = 0x37, inside an ASCII string, not a thermal profile byte
```

The fallback-to-balanced approach already has precedent in the same function's
caller for Victus S boards with an unknown EC layout, which is worth citing.

An alternative maintainers may prefer: a per-board "EC offset unknown" flag,
as the Victus S path does with `HP_EC_OFFSET_UNKNOWN`, rather than a blanket
fallback. Worth offering in the cover letter.

## 0002 — ignore the Fn+P notification echoed by a profile write

Harder to argue without a second reporter, since it depends on firmware
behaviour that may be specific to this SKU. Lead with the numbers:

```
notifications in 4 s, platform_profile registered : 824
notifications in 4 s, stock driver (no profile)   : 0
notifications in 4 s, hp_wmi unloaded             : 0
```

and the ftrace stack showing the loop:

```
platform_profile_omen_set <-_store_and_notify
 => class_for_each_device
 => platform_profile_cycle
 => wmi_notify_device
 => acpi_wmi_notify_handler
 => acpi_ev_notify_dispatch
```

A maintainer may prefer this gated behind a DMI match rather than applied to
all OMEN boards. The 300 ms guard is conservative; the observed echo latency is
about 1 ms.

Note that 0002 only becomes observable once 0001 lands, so send them as a
series in that order.

## 0003 — EC host-alive heartbeat and EC[0x29] profile read for board 8603

The most consequential of the three for users, and the hardest to upstream
as-is, because it encodes a board-specific EC watchdog. Facts to lead with:

- The DSDT's `GM10` (WMI 0x20008 / type 0x10) does exactly one thing: set EC
  field `OCCN` (EC[0x29] bit 7). OMEN Gaming Hub sends it every 90 s.
- Measured on Windows: with OCCN unrefreshed for ~6 minutes the EC pins the
  package at 45 W over PECI in every mode, MSR 0x610 and the MMIO copy still
  reading 90 W, and only a reboot releases it. With a 60 s 0x10 heartbeat from
  boot and OMEN killed, performance mode sustained 77 W for 12+ minutes.
- The mode byte is EC[0x29] bits 1:0 (`OCCM`), not 0x95, on this board.

Expect maintainers to ask for: a DMI-gated board list (already done,
`omen_occ_boards[]`), a module parameter to disable it (done,
`omen_host_alive_secs=0`), and confirmation from a second 8603 owner or a second
board with the same EC layout. `platform_profile_omen_get_ec()` could grow a
per-board EC offset+mask in `thermal_profile_params` instead of the
`is_omen_occ_board()` branch; offer that in the cover letter.

Once the post-reboot Linux measurement (README, *Verifying after a reboot*) is
in hand, include its before/after table: that is the evidence that makes 0003
land.
