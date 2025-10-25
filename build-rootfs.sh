#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/r4-config.sh"

require_root
check_bins debootstrap curl tar gzip xz sha256sum rsync chroot mount umount "${QEMU_BIN}"

ROOTFS_DIR="${WORK_DIR}/rootfs-${DISTRO}-${ARCH}"
ROOTFS_TAR="${OUT_DIR}/${DISTRO}_${ARCH}.tar.gz"
BASE_PACKAGES="\
  systemd systemd-sysv systemd-resolved udev dbus locales openssh-server nftables xz-utils hostapd iw \
  rfkill wireless-tools iproute2 iputils-ping net-tools curl ca-certificates rsync vim-tiny \
  procps less kmod ethtool iptables dnsmasq fake-hwclock systemd-timesyncd parted \
  gdisk cloud-guest-utils e2fsprogs wireless-regdb firmware-linux firmware-linux-nonfree \
  firmware-mediatek usr-is-merged"

: "${BUILD_REGDOMAIN:=${WIFI_REGDOMAIN:-}}"
: "${BUILD_REGDOMAIN:?set BUILD_REGDOMAIN, example US}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"

chroot_qemu() {
  chroot "${ROOTFS_DIR}" "${QEMU_BIN}" /bin/sh -c "$*"
}

ensure_merged_usr() {
  for d in bin sbin lib lib64; do
    if [ ! -e "${ROOTFS_DIR}/${d}" ]; then
      ln -s "usr/${d}" "${ROOTFS_DIR}/${d}"
    fi
  done
}

prepare_mountpoints() {
  mkdir -p "${ROOTFS_DIR}/proc" \
           "${ROOTFS_DIR}/sys" \
           "${ROOTFS_DIR}/dev" \
           "${ROOTFS_DIR}/dev/pts" \
           "${ROOTFS_DIR}/run"
}

populate_devtmpfs() {
  if [ ! -e "${ROOTFS_DIR}/dev/null" ]; then
    mknod -m 0666 "${ROOTFS_DIR}/dev/null" c 1 3
  fi
  if [ ! -e "${ROOTFS_DIR}/dev/zero" ]; then
    mknod -m 0666 "${ROOTFS_DIR}/dev/zero" c 1 5
  fi
  if [ ! -e "${ROOTFS_DIR}/dev/random" ]; then
    mknod -m 0666 "${ROOTFS_DIR}/dev/random" c 1 8
  fi
  if [ ! -e "${ROOTFS_DIR}/dev/urandom" ]; then
    mknod -m 0666 "${ROOTFS_DIR}/dev/urandom" c 1 9
  fi
  if [ ! -e "${ROOTFS_DIR}/dev/tty" ]; then
    mknod -m 0666 "${ROOTFS_DIR}/dev/tty" c 5 0
  fi
  if [ ! -e "${ROOTFS_DIR}/dev/console" ]; then
    mknod -m 0600 "${ROOTFS_DIR}/dev/console" c 5 1
  fi
  ln -sf pts/ptmx "${ROOTFS_DIR}/dev/ptmx"
}

mount_chroot() {
  prepare_mountpoints

  mountpoint -q "${ROOTFS_DIR}/proc" || mount -t proc proc "${ROOTFS_DIR}/proc"
  mountpoint -q "${ROOTFS_DIR}/sys" || mount -t sysfs sys "${ROOTFS_DIR}/sys"
  if ! mountpoint -q "${ROOTFS_DIR}/dev"; then
    mount -t devtmpfs devtmpfs "${ROOTFS_DIR}/dev"
    populate_devtmpfs
  fi
  if ! mountpoint -q "${ROOTFS_DIR}/dev/pts"; then
    mount -t devpts -o gid=5,mode=620,ptmxmode=000 devpts "${ROOTFS_DIR}/dev/pts"
  fi
  mountpoint -q "${ROOTFS_DIR}/run" || mount --bind /run "${ROOTFS_DIR}/run"
}

umount_chroot() {
  set +e
  umount -R "${ROOTFS_DIR}/run" 2>/dev/null
  umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null
  umount "${ROOTFS_DIR}/dev" 2>/dev/null
  umount "${ROOTFS_DIR}/sys" 2>/dev/null
  umount "${ROOTFS_DIR}/proc" 2>/dev/null
  set -e
}

cleanup() {
  umount_chroot
  rm -f "${ROOTFS_DIR}${QEMU_BIN}"
}

trap cleanup EXIT

mkdir -p "${OUT_DIR}" "${WORK_DIR}" "${ROOTFS_DIR}"
umount_chroot
rm -rf "${ROOTFS_DIR:?}"/*

DEBOOTSTRAP_MIRROR="http://deb.debian.org/debian"

echo "[INFO] Running debootstrap (stage 1)"
DEBIAN_FRONTEND=noninteractive debootstrap \
  --arch="${ARCH}" --variant=minbase --foreign --merged-usr \
  "${DISTRO}" "${ROOTFS_DIR}" "${DEBOOTSTRAP_MIRROR}"

install -D -m0755 "${QEMU_BIN}" "${ROOTFS_DIR}${QEMU_BIN}"
printf 'nameserver 1.1.1.1\n' > "${ROOTFS_DIR}/etc/resolv.conf"
if [ ! -f "${ROOTFS_DIR}/usr/share/keyrings/debian-archive-keyring.gpg" ] && \
   [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  install -D /usr/share/keyrings/debian-archive-keyring.gpg \
    "${ROOTFS_DIR}/usr/share/keyrings/debian-archive-keyring.gpg"
fi

echo "[INFO] Running debootstrap (stage 2)"
mount_chroot
chroot "${ROOTFS_DIR}" "${QEMU_BIN}" /bin/sh -c \
  "/debootstrap/debootstrap --second-stage"

ensure_merged_usr

cat > "${ROOTFS_DIR}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${ROOTFS_DIR}/usr/sbin/policy-rc.d"

printf '%s\n' "${DEBIAN_SOURCES}" > "${ROOTFS_DIR}/etc/apt/sources.list"

SETUP_SCRIPT="${ROOTFS_DIR}/tmp/rootfs-setup.sh"
mkdir -p "${ROOTFS_DIR}/tmp"
cat > "${SETUP_SCRIPT}" <<EOF
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export SYSTEMD_OFFLINE=1
apt-get -o Dpkg::Use-Pty=0 update
apt-get -o Dpkg::Use-Pty=0 install --no-install-recommends -y ${BASE_PACKAGES}
sed -i "s/^# \?en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen || true
locale-gen en_US.UTF-8
printf "LANG=en_US.UTF-8\nLANGUAGE=en_US:en\n" >/etc/default/locale
if [ ! -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  apt-get -o Dpkg::Use-Pty=0 install --no-install-recommends -y debian-archive-keyring
fi
EOF
chmod +x "${SETUP_SCRIPT}"
chroot_qemu "/tmp/rootfs-setup.sh"
rm -f "${SETUP_SCRIPT}"

for regdb in /lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s; do
  if [ ! -s "${ROOTFS_DIR}${regdb}" ]; then
    fail "missing ${regdb}"
  fi
done

if [ ! -d "${ROOTFS_DIR}/lib/firmware/mediatek" ] || \
   ! find "${ROOTFS_DIR}/lib/firmware/mediatek" -maxdepth 2 -type f -name 'mt7996*.bin' -print -quit >/dev/null 2>&1; then
  fail "mt7996 firmware absent"
fi

if [ -f "${ROOTFS_DIR}/etc/ssh/sshd_config" ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${ROOTFS_DIR}/etc/ssh/sshd_config" || true
fi
chroot_qemu 'echo root:zong0d | chpasswd'
chroot_qemu 'ln -sf /lib/systemd/system/serial-getty@.service \
  /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service'

mkdir -p "${ROOTFS_DIR}/etc/systemd/network" \
         "${ROOTFS_DIR}/etc/dnsmasq.d" \
         "${ROOTFS_DIR}/etc/systemd/system" \
         "${ROOTFS_DIR}/etc/hostapd" \
         "${ROOTFS_DIR}/etc/default" \
         "${ROOTFS_DIR}/usr/local/sbin"

cat > "${ROOTFS_DIR}/etc/systemd/network/10-wan.network" <<'EOF'
[Match]
Name=wan

[Network]
DHCP=yes

[DHCPv4]
UseDNS=yes
ClientIdentifier=mac
EOF

cat > "${ROOTFS_DIR}/etc/systemd/network/20-br-lan.netdev" <<'EOF'
[NetDev]
Name=br-lan
Kind=bridge

[Bridge]
STP=no
MulticastSnooping=no
EOF

cat > "${ROOTFS_DIR}/etc/systemd/network/21-br-lan.network" <<'EOF'
[Match]
Name=br-lan

[Network]
Address=192.168.153.1/24
IPForward=yes
EOF

cat > "${ROOTFS_DIR}/etc/systemd/network/30-lan-slaves.network" <<'EOF'
[Match]
Name=lan1 lan2 lan3

[Network]
Bridge=br-lan
EOF

cat > "${ROOTFS_DIR}/etc/systemd/network/00-names.link" <<'EOF'
[Match]
Path=platform-15020000.switch-*

[Link]
NamePolicy=kernel
EOF

cat > "${ROOTFS_DIR}/etc/dnsmasq.d/lan.conf" <<'EOF'
interface=br-lan
bind-interfaces
dhcp-range=192.168.153.100,192.168.153.200,12h
dhcp-option=option:router,192.168.153.1
dhcp-option=option:dns-server,192.168.153.1
EOF

install -D -m0644 "${SCRIPT_DIR}/conf/generic/etc/hostapd/hostapd.conf" \
  "${ROOTFS_DIR}/etc/hostapd/hostapd.conf"
sed -ri \
  "s/^country=.*/country=${BUILD_REGDOMAIN}/" \
  "${ROOTFS_DIR}/etc/hostapd/hostapd.conf"
sed -ri \
  "s/^interface=.*/interface=${WIFI_IFACE}/" \
  "${ROOTFS_DIR}/etc/hostapd/hostapd.conf"

cat > "${ROOTFS_DIR}/etc/systemd/network/zz-99-${WIFI_IFACE}.network" <<EOF
[Match]
Name=${WIFI_IFACE}

[Network]
DHCP=no
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF

cat > "${ROOTFS_DIR}/etc/default/hostapd" <<'EOF'
DAEMON_CONF="/etc/hostapd/hostapd.conf"
RUN_DAEMON="yes"
EOF

cat > "${ROOTFS_DIR}/etc/nftables.conf" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0;
    ct state established,related accept
    iif lo accept
    tcp dport { 22, 53, 67, 68 } accept
    udp dport { 53, 67, 68 } accept
    ip protocol icmp accept
    counter drop
  }

  chain forward {
    type filter hook forward priority 0;
    accept
  }

  chain output {
    type filter hook output priority 0;
    accept
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100;
  }

  chain postrouting {
    type nat hook postrouting priority 100;
    oifname "wan" masquerade
  }
}
EOF

install -D -m0644 "${SCRIPT_DIR}/conf/generic/lib/systemd/system/wlan-prepare@.service" \
  "${ROOTFS_DIR}/lib/systemd/system/wlan-prepare@.service"
sed -ri \
  "s/@REGDOMAIN@/${BUILD_REGDOMAIN}/" \
  "${ROOTFS_DIR}/lib/systemd/system/wlan-prepare@.service"

install -d -m0755 "${ROOTFS_DIR}/etc/systemd/system/hostapd.service.d"
cat > "${ROOTFS_DIR}/etc/systemd/system/hostapd.service.d/override.conf" <<'EOF'
[Service]
Restart=on-failure
RestartSec=2
EOF

cat > "${ROOTFS_DIR}/usr/local/sbin/wifi-health.sh" <<'EOF'
#!/bin/sh
set -eu

print_section() {
  printf '\n== %s ==\n' "$1"
}

if ! command -v iw >/dev/null 2>&1; then
  echo "[WARN] iw is not available; Wi-Fi checks will be limited" >&2
fi

print_section "Regulatory domain"
if command -v iw >/dev/null 2>&1; then
  iw reg get || true
else
  echo "iw not installed"
fi

print_section "Regulatory database"
if [ -e /lib/firmware/regulatory.db ]; then
  readlink -f /lib/firmware/regulatory.db || true
else
  echo "regulatory.db missing"
fi

print_section "Primary radio"
if command -v iw >/dev/null 2>&1; then
  iw dev @WIFI_IFACE@ info || true
else
  echo "iw not installed"
fi

print_section "PHY EHT/HE capabilities"
if command -v iw >/dev/null 2>&1; then
  phy_list=$(ls /sys/class/ieee80211 2>/dev/null || true)
  if [ -n "${phy_list}" ]; then
    for phy in ${phy_list}; do
      printf '[%s]\n' "${phy}"
      iw phy "${phy}" info | grep -nE 'EHT|HE|320|160' || true
    done
  else
    echo "No PHYs detected"
  fi
else
  echo "iw not installed"
fi

print_section "cfg80211 recent logs"
dmesg | grep -i cfg80211 | tail -n 20 || true

print_section "hostapd status"
systemctl status hostapd --no-pager || true

print_section "nftables status"
systemctl status nftables --no-pager || true

print_section "nftables ruleset"
nft list ruleset || true
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/wifi-health.sh"
sed -i "s/@WIFI_IFACE@/${WIFI_IFACE}/" "${ROOTFS_DIR}/usr/local/sbin/wifi-health.sh"

cat > "${ROOTFS_DIR}/usr/local/sbin/firstboot-grow.sh" <<'EOF'
#!/bin/sh
set -eu

disk=/dev/mmcblk0
part=${disk}p6

sgdisk -e "${disk}" || true
partprobe "${disk}" || true
growpart "${disk}" 6 || true
resize2fs "${part}" || true

systemctl disable firstboot-grow.service || true
rm -f /etc/systemd/system/multi-user.target.wants/firstboot-grow.service
rm -f /etc/systemd/system/firstboot-grow.service
EOF
chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/firstboot-grow.sh"

cat > "${ROOTFS_DIR}/etc/systemd/system/firstboot-grow.service" <<'EOF'
[Unit]
Description=One-time GPT expand and rootfs grow
ConditionFirstBoot=yes
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot-grow.sh

[Install]
WantedBy=multi-user.target
EOF

# Enable services directly from the host because the chroot does not have a
# running systemd instance. Using --root performs the enablement offline while
# still respecting the units' Install metadata.
if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required to enable services inside the rootfs" >&2
  exit 1
fi

mount_chroot
SYSTEMCTL_CMD=(systemctl --root="${ROOTFS_DIR}" --no-ask-password)
SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" preset-all || true

SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" mask \
  wpa_supplicant.service wpa_supplicant@.service || true

for unit in \
  systemd-networkd.service \
  systemd-resolved.service \
  nftables.service \
  hostapd.service \
  dnsmasq.service \
  systemd-timesyncd.service \
  firstboot-grow.service
do
  SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable "${unit}" || true
done

SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable \
  "wlan-prepare@${WIFI_IFACE}.service" || true

if [ -L "${ROOTFS_DIR}/etc/systemd/system/fake-hwclock.service" ] && \
   [ "$(readlink "${ROOTFS_DIR}/etc/systemd/system/fake-hwclock.service")" = "/dev/null" ]; then
  echo "[INFO] fake-hwclock.service is masked; skipping enable"
else
  echo "[INFO] Leaving fake-hwclock.service at its packaged default state"
fi
chroot_qemu 'rm -f /etc/resolv.conf && ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf'

mkdir -p "${ROOTFS_DIR}/lib/firmware"

if [ -d "${FIRMWARE_DIR}" ] && \
   find "${FIRMWARE_DIR}" -mindepth 1 -print -quit >/dev/null 2>&1; then
  rsync -a "${FIRMWARE_DIR}/" "${ROOTFS_DIR}/lib/firmware/"
fi

MT7996_DIR="${ROOTFS_DIR}/lib/firmware/mediatek/mt7996"
if [ -d "${MT7996_DIR}" ]; then
  (
    cd "${MT7996_DIR}" || exit 0
    if [ -f mt7996_eeprom_233.bin ] && [ ! -e mt7996_eeprom_bpi_r4.bin ]; then
      ln -sf mt7996_eeprom_233.bin mt7996_eeprom_bpi_r4.bin
    fi
    if [ -e mt7996_eeprom_bpi_r4.bin ] && [ ! -e mt7996_eeprom_233_2i5i6i.bin ]; then
      ln -sf mt7996_eeprom_bpi_r4.bin mt7996_eeprom_233_2i5i6i.bin
    fi
    if [ -f mt7996_wm_233.bin ] && [ ! -e mt7996_wm.bin ]; then
      ln -sf mt7996_wm_233.bin mt7996_wm.bin
    fi
    if [ -f mt7996_wa_233.bin ] && [ ! -e mt7996_wa.bin ]; then
      ln -sf mt7996_wa_233.bin mt7996_wa.bin
    fi
    if [ -f mt7996_rom_patch_233.bin ] && [ ! -e mt7996_rom_patch.bin ]; then
      ln -sf mt7996_rom_patch_233.bin mt7996_rom_patch.bin
    fi
  )
fi

chroot_qemu 'apt-get -o Dpkg::Use-Pty=0 clean'
rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/*
rm -f "${ROOTFS_DIR}/usr/sbin/policy-rc.d"

umount_chroot

rm -f "${ROOTFS_DIR}${QEMU_BIN}"

echo "[INFO] Packing ${ROOTFS_TAR}"
tar --sort=name --mtime='@0' --numeric-owner --owner=0 --group=0 \
  -C "${ROOTFS_DIR}" -cf - . | gzip -n > "${ROOTFS_TAR}"
sha256sum "${ROOTFS_TAR}" > "${ROOTFS_TAR}.sha256"

echo "[OK] Root filesystem tarball ready: ${ROOTFS_TAR}"
