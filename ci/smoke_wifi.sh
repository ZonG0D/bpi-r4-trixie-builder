#!/bin/bash
set -euo pipefail
root="${1:-/}"
chroot_cmd() { chroot "$root" /bin/sh -lc "$*"; }

# regdb must exist and kernel must accept it on boot, but here just check files
test -s "$root/lib/firmware/regulatory.db"
test -s "$root/lib/firmware/regulatory.db.p7s" || true

# hostapd units present
for i in wlp1s0 wlan1 wlan2; do
  test -s "$root/etc/hostapd/hostapd-$i.conf"
done
test -s "$root/etc/systemd/system/hostapd@.service"

# bridge config present
test -s "$root/etc/systemd/network/br-lan.netdev"
test -s "$root/etc/systemd/network/br-lan.network"

# udev rule generator installed
test -x "$root/usr/local/sbin/gen-wifi-udev-rules.sh"
