#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
log_start "build-rootfs"

check_bins debootstrap chroot tar gzip sha256sum rsync

ROOTFS_DIR="${WORK_DIR}/rootfs"
mkdir -p "${ROOTFS_DIR}"
rm -rf "${ROOTFS_DIR:?}"/*

if [ ! -x "${QEMU_BIN}" ]; then
    echo "[ERROR] QEMU binary not found at ${QEMU_BIN}" >&2
    exit 1
fi

DEBOOTSTRAP_LOG="${LOG_DIR}/debootstrap.log"

echo "[INFO] Running debootstrap (stage 1)"
DEBIAN_FRONTEND=noninteractive debootstrap \
    --arch="${ARCH}" --foreign --variant=minbase \
    "${DISTRO}" "${ROOTFS_DIR}" "${MIRROR_MAIN}" \
    >>"${DEBOOTSTRAP_LOG}" 2>&1

cp "${QEMU_BIN}" "${ROOTFS_DIR}${QEMU_BIN}"

mount_chroot() {
    for dir in proc sys dev dev/pts; do
        mkdir -p "${ROOTFS_DIR}/${dir}"
    done
    mount -t proc /proc "${ROOTFS_DIR}/proc"
    mount --rbind /sys "${ROOTFS_DIR}/sys"
    mount --make-rslave "${ROOTFS_DIR}/sys"
    mount --rbind /dev "${ROOTFS_DIR}/dev"
    mount --make-rslave "${ROOTFS_DIR}/dev"
    mount --rbind /dev/pts "${ROOTFS_DIR}/dev/pts"
}

umount_chroot() {
    for dir in dev/pts dev sys proc; do
        if mountpoint -q "${ROOTFS_DIR}/${dir}"; then
            umount -R "${ROOTFS_DIR}/${dir}"
        fi
    done
}

cleanup() {
    umount_chroot || true
}

trap cleanup EXIT

mount_chroot

echo "[INFO] Running debootstrap (stage 2)"
chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage

mkdir -p "${ROOTFS_DIR}/etc/apt"
cat <<SOURCES > "${ROOTFS_DIR}/etc/apt/sources.list"
${DEBIAN_SOURCES}
SOURCES

echo 'Acquire::Languages "none";' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99nolanguages"
echo 'APT::Install-Recommends "0";' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99norecommends"

echo "[INFO] Configuring locale"
chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get update
chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y locales openssh-server nftables xz-utils hostapd iw
chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends ca-certificates net-tools

chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get clean
rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/* "${ROOTFS_DIR}/var/cache/apt/archives"/*

chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    locale-gen en_US.UTF-8
chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    update-locale LANG=en_US.UTF-8

printf 'LANG=en_US.UTF-8\n' > "${ROOTFS_DIR}/etc/default/locale"

SSH_CONFIG="${ROOTFS_DIR}/etc/ssh/sshd_config"
if grep -q '^PermitRootLogin' "${SSH_CONFIG}"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "${SSH_CONFIG}"
else
    printf '\nPermitRootLogin yes\n' >> "${SSH_CONFIG}"
fi

echo "root:zong0d" | chroot "${ROOTFS_DIR}" chpasswd

mkdir -p "${ROOTFS_DIR}/etc/network/interfaces.d"
mkdir -p "${ROOTFS_DIR}/etc/hostapd"
install -m 0644 "${CONF_DIR}/interfaces" "${ROOTFS_DIR}/etc/network/interfaces.d/bpi-r4"
install -m 0644 "${CONF_DIR}/hostapd.conf" "${ROOTFS_DIR}/etc/hostapd/hostapd.conf"
mkdir -p "${ROOTFS_DIR}/etc/nftables.conf.d"
install -m 0644 "${CONF_DIR}/nftables.nft" "${ROOTFS_DIR}/etc/nftables.conf.d/bpi-r4.nft"

cat <<'HOSTAPD' > "${ROOTFS_DIR}/etc/default/hostapd"
DAEMON_CONF="/etc/hostapd/hostapd.conf"
DAEMON_OPTS=""
HOSTAPD

cat <<'NFTMAIN' > "${ROOTFS_DIR}/etc/nftables.conf"
include "/etc/nftables.conf.d/bpi-r4.nft"
NFTMAIN

mkdir -p "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 "${CONF_DIR}/wifi-check.sh" "${ROOTFS_DIR}/usr/local/sbin/wifi-check.sh"
install -m 0644 "${CONF_DIR}/wifi-check.service" "${ROOTFS_DIR}/etc/systemd/system/wifi-check.service"

chroot "${ROOTFS_DIR}" systemctl enable ssh
chroot "${ROOTFS_DIR}" systemctl enable hostapd
chroot "${ROOTFS_DIR}" systemctl enable nftables
chroot "${ROOTFS_DIR}" systemctl enable wifi-check.service

echo "${BOARD}" > "${ROOTFS_DIR}/etc/hostname"

rm -f "${ROOTFS_DIR}/etc/ssh/ssh_host_"*

cat <<'HOSTS' > "${ROOTFS_DIR}/etc/hosts"
127.0.0.1   localhost
127.0.1.1   bpi-r4

# IPv6 defaults
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS

if [ -d "${FIRMWARE_DIR}" ] && find "${FIRMWARE_DIR}" -mindepth 1 -print -quit >/dev/null 2>&1; then
    echo "[INFO] Copying firmware blobs"
    rsync -a "${FIRMWARE_DIR}/" "${ROOTFS_DIR}/lib/firmware/"
fi

rm -f "${ROOTFS_DIR}${QEMU_BIN}"

umount_chroot
trap - EXIT

find "${ROOTFS_DIR}" -print0 | xargs -0 touch -h -d '@0'

mkdir -p "${OUT_DIR}"
ROOTFS_TAR="${OUT_DIR}/${DISTRO}_${ARCH}.tar"
ROOTFS_TAR_GZ="${ROOTFS_TAR}.gz"

rm -f "${ROOTFS_TAR}" "${ROOTFS_TAR_GZ}"

tar --numeric-owner --owner=0 --group=0 --sort=name --mtime='@0' \
    -C "${ROOTFS_DIR}" -cf "${ROOTFS_TAR}" .

gzip -n "${ROOTFS_TAR}"

sha256sum "${ROOTFS_TAR_GZ}" > "${ROOTFS_TAR_GZ}.sha256"

echo "[OK] Root filesystem ready: ${ROOTFS_TAR_GZ}"
