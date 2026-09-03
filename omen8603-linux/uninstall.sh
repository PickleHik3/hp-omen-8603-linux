#!/usr/bin/env bash
# Remove the patched hp-wmi driver and restore the in-tree module.
set -euo pipefail
NAME=hp-wmi-8603
VER=1.1
[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

systemctl disable --now omen-power.service 2>/dev/null || true
rm -f /etc/systemd/system/omen-power.service /usr/local/bin/omen-power
systemctl daemon-reload
dkms remove -m $NAME -v $VER --all || true
dkms remove -m $NAME -v 1.0 --all 2>/dev/null || true
rm -rf "/usr/src/$NAME-1.0"
rm -rf "/usr/src/$NAME-$VER"
depmod -a
modprobe -r hp_wmi 2>/dev/null || true
modprobe hp_wmi 2>/dev/null || true
echo "restored: $(modinfo -n hp_wmi)"
systemctl is-active --quiet power-profiles-daemon && systemctl restart power-profiles-daemon || true
