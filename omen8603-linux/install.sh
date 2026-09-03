#!/usr/bin/env bash
# Install the patched hp-wmi driver for OMEN board 8603 via DKMS.
set -euo pipefail

NAME=hp-wmi-8603
VER=1.1
SRC="$(cd "$(dirname "$0")" && pwd)/src"

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

board=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)
if [[ $board != 8603 ]]; then
    echo "warning: this board is '$board', not 8603." >&2
    echo "The patches are harmless elsewhere but were only verified here." >&2
    read -rp "continue? [y/N] " a; [[ ${a,,} == y ]] || exit 1
fi

command -v dkms >/dev/null || { echo "dkms is not installed (pacman -S dkms)" >&2; exit 1; }
[[ -d /usr/lib/modules/$(uname -r)/build ]] || {
    echo "kernel headers for $(uname -r) are missing (pacman -S linux-headers)" >&2; exit 1; }

# Drop every registered version of this package (older ones included) so only
# one copy of hp-wmi.ko ever lands in /updates/dkms.
for old in $(dkms status -m $NAME 2>/dev/null | sed -n 's|^'"$NAME"'[/,] *\([^,]*\),.*|\1|p' | sort -u); do
    dkms remove -m $NAME -v "$old" --all >/dev/null 2>&1 || true
    rm -rf "/usr/src/$NAME-$old"
done

rm -rf "/usr/src/$NAME-$VER"
install -d "/usr/src/$NAME-$VER"
install -m644 "$SRC/hp-wmi.c" "$SRC/Makefile" "$SRC/dkms.conf" "/usr/src/$NAME-$VER/"

dkms install -m $NAME -v $VER --force

echo
echo "installed: $(modinfo -n hp_wmi)"
echo "reloading module..."
modprobe -r hp_wmi 2>/dev/null || true
modprobe hp_wmi
sleep 1

if [[ -e /sys/class/platform-profile/platform-profile-0/profile ]]; then
    echo "OK: platform_profile registered -> $(cat /sys/class/platform-profile/platform-profile-0/choices)"
else
    echo "FAILED: no platform_profile. Check: dmesg | grep hp_wmi" >&2
    exit 1
fi

systemctl is-active --quiet power-profiles-daemon &&
    systemctl restart power-profiles-daemon &&
    echo "restarted power-profiles-daemon so it picks up the new platform driver"

# RAPL follower: keeps MSR PL1/PL2 where OMEN Gaming Hub would put them per mode.
TOOLS="$(cd "$(dirname "$0")" && pwd)/tools"
UNITS="$(cd "$(dirname "$0")" && pwd)/systemd"
install -m755 "$TOOLS/omen-power" /usr/local/bin/omen-power
install -m644 "$UNITS/omen-power.service" /etc/systemd/system/omen-power.service
systemctl daemon-reload
systemctl enable --now omen-power.service
echo "omen-power.service enabled: $(systemctl is-active omen-power.service)"
echo
/usr/local/bin/omen-power status
