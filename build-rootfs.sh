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

PKGS_BASE="systemd-sysv dbus iproute2 iptables nftables ca-certificates jq curl iw rfkill ethtool bridge-utils"
PKGS_WIFI="hostapd wireless-regdb"
PKGS_DEBUG="tcpdump iperf3 procps kmod"
DEBOOTSTRAP_PKGS="${PKGS_BASE} ${PKGS_WIFI} ${PKGS_DEBUG}"

: "${BUILD_REGDOMAIN:=${WIFI_REGDOMAIN:-}}"
: "${BUILD_REGDOMAIN:?set BUILD_REGDOMAIN, example US}"
WIFI_IFACE_2G="${WIFI_IFACE_2G:-wlan0}"
WIFI_IFACE_5G="${WIFI_IFACE_5G:-wlan1}"
WIFI_IFACE_6G="${WIFI_IFACE_6G:-wlan2}"
if [ -n "${WIFI_IFACE:-}" ]; then
  WIFI_IFACE_5G="${WIFI_IFACE}"
fi
WIFI_IFACES=("${WIFI_IFACE_2G}" "${WIFI_IFACE_5G}" "${WIFI_IFACE_6G}")

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
           "${ROOTFS_DIR}/sys/fs/cgroup" \
           "${ROOTFS_DIR}/dev" \
           "${ROOTFS_DIR}/dev/pts" \
           "${ROOTFS_DIR}/dev/mqueue" \
           "${ROOTFS_DIR}/run"

  if [ ! -L "${ROOTFS_DIR}/dev/shm" ]; then
    mkdir -p "${ROOTFS_DIR}/dev/shm"
  fi
}

resolve_tty_gid() {
  local tty_gid=5

  if [ -f "${ROOTFS_DIR}/etc/group" ]; then
    local group_gid
    group_gid="$(awk -F: '$1 == "tty" { print $3; exit }' "${ROOTFS_DIR}/etc/group" 2>/dev/null || true)"
    case "${group_gid}" in
      ''|*[!0-9]*) ;;
      *) tty_gid="${group_gid}" ;;
    esac
  fi

  printf '%s' "${tty_gid}"
}

populate_devtmpfs_gaps() {
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
}

ensure_dev_symlinks() {
  ln -snf /proc/self/fd "${ROOTFS_DIR}/dev/fd"
  ln -snf fd/0 "${ROOTFS_DIR}/dev/stdin"
  ln -snf fd/1 "${ROOTFS_DIR}/dev/stdout"
  ln -snf fd/2 "${ROOTFS_DIR}/dev/stderr"
  rm -f "${ROOTFS_DIR}/dev/ptmx"
  ln -s pts/ptmx "${ROOTFS_DIR}/dev/ptmx"
}

have_fs() {
  awk '{print $1}' /proc/filesystems | grep -qx "$1"
}

mount_chroot() {
  prepare_mountpoints

  mountpoint -q "${ROOTFS_DIR}/proc" || mount -t proc -o nosuid,nodev,noexec proc "${ROOTFS_DIR}/proc"
  mountpoint -q "${ROOTFS_DIR}/sys" || mount -t sysfs sys "${ROOTFS_DIR}/sys"

  local mounted_devtmpfs=0
  if ! mountpoint -q "${ROOTFS_DIR}/dev"; then
    mount -t devtmpfs -o mode=0755,nosuid devtmpfs "${ROOTFS_DIR}/dev"
    mounted_devtmpfs=1
  fi

  if [ "${mounted_devtmpfs}" -eq 1 ]; then
    populate_devtmpfs_gaps
  fi

  if ! mountpoint -q "${ROOTFS_DIR}/dev/pts"; then
    # Use a private devpts instance so mount options do not leak back to the host
    # (which can otherwise break new PTY allocation on the developer machine).
    local devpts_gid devpts_opts devpts_newinstance=0
    devpts_gid="$(resolve_tty_gid)"
    devpts_opts="gid=${devpts_gid},mode=0620,ptmxmode=0666"
    if [ -e /sys/module/devpts/parameters/newinstance ]; then
      devpts_newinstance=1
    fi
    if [ "${devpts_newinstance}" -eq 1 ]; then
      if ! mount -t devpts -o "newinstance,${devpts_opts}" devpts "${ROOTFS_DIR}/dev/pts" 2>/dev/null; then
        mount -t devpts -o "${devpts_opts}" devpts "${ROOTFS_DIR}/dev/pts"
      fi
    else
      mount -t devpts -o "${devpts_opts}" devpts "${ROOTFS_DIR}/dev/pts"
    fi
  fi

  ensure_dev_symlinks

  if [ ! -L "${ROOTFS_DIR}/dev/ptmx" ] || [ "$(readlink "${ROOTFS_DIR}/dev/ptmx")" != "pts/ptmx" ]; then
    echo "/dev/ptmx must point to pts/ptmx" >&2
    exit 1
  fi
  if [ ! -c "${ROOTFS_DIR}/dev/pts/ptmx" ]; then
    echo "devpts misconfigured, missing pts/ptmx" >&2
    exit 1
  fi

  if [ ! -L "${ROOTFS_DIR}/dev/shm" ] && ! mountpoint -q "${ROOTFS_DIR}/dev/shm"; then
    mount -t tmpfs -o nosuid,nodev,noexec,mode=1777 tmpfs "${ROOTFS_DIR}/dev/shm"
  fi
  if have_fs mqueue && ! mountpoint -q "${ROOTFS_DIR}/dev/mqueue"; then
    mount -t mqueue mqueue "${ROOTFS_DIR}/dev/mqueue"
  fi
  if ! mountpoint -q "${ROOTFS_DIR}/run"; then
    mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs "${ROOTFS_DIR}/run"
  fi

  if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    if ! mountpoint -q "${ROOTFS_DIR}/sys/fs/cgroup"; then
      if ! mount -t cgroup2 -o ro,nsdelegate cgroup2 "${ROOTFS_DIR}/sys/fs/cgroup" 2>/dev/null; then
        mount -t cgroup2 -o ro cgroup2 "${ROOTFS_DIR}/sys/fs/cgroup" 2>/dev/null || true
      fi
    fi
  fi
}

umount_one() {
  umount "$1" 2>/dev/null || umount -l "$1" 2>/dev/null || true
}

umount_chroot() {
  set +e
  umount -R "${ROOTFS_DIR}/run" 2>/dev/null || umount -l "${ROOTFS_DIR}/run" 2>/dev/null
  umount_one "${ROOTFS_DIR}/dev/shm"
  umount_one "${ROOTFS_DIR}/dev/mqueue"
  umount_one "${ROOTFS_DIR}/dev/pts"
  umount_one "${ROOTFS_DIR}/sys/fs/cgroup"
  umount_one "${ROOTFS_DIR}/dev"
  umount_one "${ROOTFS_DIR}/sys"
  umount_one "${ROOTFS_DIR}/proc"
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
  --include="${DEBOOTSTRAP_PKGS}" \
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
apt-get -o Dpkg::Use-Pty=0 install --no-install-recommends -y \
  ${BASE_PACKAGES} ${PKGS_BASE} ${PKGS_WIFI} ${PKGS_DEBUG}
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

rm -f "${ROOTFS_DIR}/lib/firmware/regulatory.db" \
      "${ROOTFS_DIR}/lib/firmware/regulatory.db.p7s"
chroot_qemu 'apt-get -o Dpkg::Use-Pty=0 install --no-install-recommends -y --reinstall wireless-regdb'

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
DHCP=ipv4
LinkLocalAddressing=no
IPv6AcceptRA=no

[DHCPv4]
UseDNS=yes
ClientIdentifier=mac
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

install -D -m0644 "${SCRIPT_DIR}/files/etc/udev/rules.d/76-wifi-names.rules" \
  "${ROOTFS_DIR}/etc/udev/rules.d/76-wifi-names.rules"

install -D -m0755 "${SCRIPT_DIR}/files/usr/local/sbin/gen-wifi-udev-rules.sh" \
  "${ROOTFS_DIR}/usr/local/sbin/gen-wifi-udev-rules.sh"
install -D -m0644 "${SCRIPT_DIR}/files/etc/systemd/system/firstboot-wifi-udev.service" \
  "${ROOTFS_DIR}/etc/systemd/system/firstboot-wifi-udev.service"

install -D -m0644 "${SCRIPT_DIR}/files/etc/hostapd/hostapd-wlan0.conf" \
  "${ROOTFS_DIR}/etc/hostapd/hostapd-wlan0.conf"
install -D -m0644 "${SCRIPT_DIR}/files/etc/hostapd/hostapd-wlan1.conf" \
  "${ROOTFS_DIR}/etc/hostapd/hostapd-wlan1.conf"
install -D -m0644 "${SCRIPT_DIR}/files/etc/hostapd/hostapd-wlan2.conf" \
  "${ROOTFS_DIR}/etc/hostapd/hostapd-wlan2.conf"

install -D -m0644 "${SCRIPT_DIR}/files/etc/systemd/system/hostapd@.service" \
  "${ROOTFS_DIR}/etc/systemd/system/hostapd@.service"

install -D -m0644 "${SCRIPT_DIR}/files/etc/systemd/network/br-lan.netdev" \
  "${ROOTFS_DIR}/etc/systemd/network/br-lan.netdev"
install -D -m0644 "${SCRIPT_DIR}/files/etc/systemd/network/br-lan.network" \
  "${ROOTFS_DIR}/etc/systemd/network/br-lan.network"

bash "${SCRIPT_DIR}/ci/smoke_wifi.sh" "${ROOTFS_DIR}"

rm -f "${ROOTFS_DIR}"/etc/systemd/network/wlan*.network \
      "${ROOTFS_DIR}"/etc/network/interfaces.d/wlan* || true

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
    ct state established,related accept
    iifname { "br-lan", "br-wan-2g", "br-wan-5g", "br-wan-6g" } oifname "wan" accept
    counter drop
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

WIFI_INTERFACES="@WIFI_INTERFACES@"

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

print_section "Radio summary"
if command -v iw >/dev/null 2>&1; then
  for iface in ${WIFI_INTERFACES}; do
    [ -n "${iface}" ] || continue
    printf '[%s]\n' "${iface}"
    iw dev "${iface}" info || true
    printf '\n'
  done
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
wifi_interfaces_string="$(printf '%s ' "${WIFI_IFACES[@]}")"
wifi_interfaces_string="${wifi_interfaces_string% }"
sed -i "s|@WIFI_INTERFACES@|${wifi_interfaces_string}|g" \
  "${ROOTFS_DIR}/usr/local/sbin/wifi-health.sh"

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
  systemd-timesyncd.service \
  firstboot-grow.service
do
  SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable "${unit}" || true
done

SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable firstboot-wifi-udev.service || true
SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable hostapd@wlan0.service || true
SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable hostapd@wlan1.service || true
SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable hostapd@wlan2.service || true

for iface in "${WIFI_IFACES[@]}"; do
  [ -n "${iface}" ] || continue
  SYSTEMD_OFFLINE=1 "${SYSTEMCTL_CMD[@]}" enable \
    "wlan-prepare@${iface}.service" || true
done

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
