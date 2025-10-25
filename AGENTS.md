Runtime verification.

1. After first boot, confirm udev rule is generated.
   ls -l /etc/udev/rules.d/76-wifi-names.rules
   udevadm info -q property -p /sys/class/net/wlan0 | grep -i address

2. Confirm regulatory DB accepted.
   dmesg | grep -i cfg80211 | tail -n +1
   iw reg get | grep country

3. Check hostapd instances.
   systemctl status hostapd@wlan0 hostapd@wlan1 hostapd@wlan2
   journalctl -u hostapd@* -b

4. Confirm AP state.
   iw dev
   iw dev wlan0 info
   iw dev wlan1 info
   iw dev wlan2 info

Expected.
- No "regulatory.db ... malformed" messages.
- wlan0 type AP channel 1, wlan1 type AP channel 36, wlan2 type AP channel 5 with SAE.
- br-lan up. BSS ifnames enslaved to br-lan after hostapd start.
