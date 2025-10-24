#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
check_bins debootstrap curl tar gzip xz sha256sum rsync "${QEMU_BIN}"

ROOTFS_DIR="${WORK_DIR}/rootfs-${DISTRO}-${ARCH}"
ROOTFS_TAR="${OUT_DIR}/${DISTRO}_${ARCH}.tar.gz"

chroot_qemu() {
  chroot "${ROOTFS_DIR}" "${QEMU_BIN}" /bin/bash -lc "$*"
}

prepare_mountpoints() {
  mkdir -p "${ROOTFS_DIR}/proc" \
           "${ROOTFS_DIR}/sys" \
           "${ROOTFS_DIR}/dev" \
           "${ROOTFS_DIR}/dev/pts" \
           "${ROOTFS_DIR}/run"
}

mount_chroot() {
  prepare_mountpoints
  mount -t proc proc "${ROOTFS_DIR}/proc"
  mount -t sysfs sys "${ROOTFS_DIR}/sys"
  mount --bind /dev "${ROOTFS_DIR}/dev"
  mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
  mount --bind /run "${ROOTFS_DIR}/run" || true
}

umount_chroot() {
  set +e
  umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null
  umount -l "${ROOTFS_DIR}/dev" 2>/dev/null
  umount -l "${ROOTFS_DIR}/proc" 2>/dev/null
  umount -l "${ROOTFS_DIR}/sys" 2>/dev/null
  umount -l "${ROOTFS_DIR}/run" 2>/dev/null
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
  --arch="${ARCH}" --variant=minbase --foreign \
  "${DISTRO}" "${ROOTFS_DIR}" "${DEBOOTSTRAP_MIRROR}"

install -D "${QEMU_BIN}" "${ROOTFS_DIR}${QEMU_BIN}"
install -D /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"
if [ ! -f "${ROOTFS_DIR}/usr/share/keyrings/debian-archive-keyring.gpg" ] && \
   [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  install -D /usr/share/keyrings/debian-archive-keyring.gpg \
    "${ROOTFS_DIR}/usr/share/keyrings/debian-archive-keyring.gpg"
fi

echo "[INFO] Running debootstrap (stage 2)"
mount_chroot
chroot "${ROOTFS_DIR}" "${QEMU_BIN}" /bin/sh -c \
  "/debootstrap/debootstrap --second-stage"

cat > "${ROOTFS_DIR}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "${ROOTFS_DIR}/usr/sbin/policy-rc.d"

printf '%s\n' "${DEBIAN_SOURCES}" > "${ROOTFS_DIR}/etc/apt/sources.list"

chroot_qemu 'export DEBIAN_FRONTEND=noninteractive; apt-get update'
chroot_qemu 'export DEBIAN_FRONTEND=noninteractive; test -f /usr/share/keyrings/debian-archive-keyring.gpg || apt-get -y --no-install-recommends install debian-archive-keyring'

chroot_qemu 'export DEBIAN_FRONTEND=noninteractive; apt-get update'
chroot_qemu 'export DEBIAN_FRONTEND=noninteractive; apt-get -y --no-install-recommends install locales'
# locale-gen might fail if the locale is already generated, so ignore errors.
chroot_qemu 'locale-gen en_US.UTF-8 || true'
# update-locale is not available in the minimal environment, so configure it manually.
cat > "${ROOTFS_DIR}/etc/default/locale" <<'EOF'
LANG="en_US.UTF-8"
LC_ALL="en_US.UTF-8"
EOF
chroot_qemu 'export DEBIAN_FRONTEND=noninteractive; apt-get -y --no-install-recommends install \
  systemd-sysv openssh-server iproute2 nftables xz-utils hostapd iw ca-certificates curl'

if [ -f "${ROOTFS_DIR}/etc/ssh/sshd_config" ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${ROOTFS_DIR}/etc/ssh/sshd_config" || true
fi
chroot_qemu 'echo root:bananapi | chpasswd'

mkdir -p "${ROOTFS_DIR}/lib/firmware"

if [ -d "${FIRMWARE_DIR}" ] && \
   find "${FIRMWARE_DIR}" -mindepth 1 -print -quit >/dev/null 2>&1; then
  rsync -a "${FIRMWARE_DIR}/" "${ROOTFS_DIR}/lib/firmware/"
fi

chroot_qemu 'apt-get clean'
rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/*
rm -f "${ROOTFS_DIR}/usr/sbin/policy-rc.d"

umount_chroot
trap - EXIT

rm -f "${ROOTFS_DIR}${QEMU_BIN}"

echo "[INFO] Packing ${ROOTFS_TAR}"
GZIP=-n tar --sort=name --mtime='@0' --numeric-owner --owner=0 --group=0 \
  -C "${ROOTFS_DIR}" -czf "${ROOTFS_TAR}" .
sha256sum "${ROOTFS_TAR}" > "${ROOTFS_TAR}.sha256"

echo "[OK] Root filesystem tarball ready: ${ROOTFS_TAR}"
