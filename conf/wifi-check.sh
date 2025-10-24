#!/bin/sh
set -eu

LOG=/var/log/wifi-check.log
{
    echo "--- $(date -u --iso-8601=seconds) ---"
    lsmod | grep mt76 || echo "mt76 module missing"
    dmesg | grep -i mediatek || echo "mediatek logs missing"
} >> "$LOG" 2>&1
