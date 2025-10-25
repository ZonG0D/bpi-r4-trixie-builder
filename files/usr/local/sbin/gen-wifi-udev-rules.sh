#!/bin/sh
set -eu
RULE=/etc/udev/rules.d/76-wifi-names.rules
# If already populated with MACs, exit.
grep -q 'ATTR{address}==' "$RULE" 2>/dev/null && exit 0

# Discover MACs deterministically by phy index.
MAC0=$(cat /sys/class/ieee80211/phy0/macaddress 2>/dev/null || true)
MAC1=$(cat /sys/class/ieee80211/phy1/macaddress 2>/dev/null || true)
MAC2=$(cat /sys/class/ieee80211/phy2/macaddress 2>/dev/null || true)

tmp=$(mktemp)
{
  [ -n "$MAC0" ] && printf 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="%s", NAME="wlan0"\n' "$MAC0"
  [ -n "$MAC1" ] && printf 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="%s", NAME="wlan1"\n' "$MAC1"
  [ -n "$MAC2" ] && printf 'SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="%s", NAME="wlan2"\n' "$MAC2"
} >"$tmp"

if [ -s "$tmp" ]; then
  mv "$tmp" "$RULE"
  udevadm control --reload
fi
