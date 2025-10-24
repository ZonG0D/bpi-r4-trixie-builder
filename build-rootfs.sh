#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
check_bins debootstrap curl xz gzip tar sha256sum "${QEMU_BIN}"

ROOT="${WORK_DIR}/rootfs-${DISTRO}-${ARCH}"
TAR="${OUT_DIR}/${DISTRO}_${ARCH}.tar.gz"
mkdir -p "${ROOT}" "${OUT_DIR}" "${WORK_DIR}"
rm -rf "${ROOT:?}"/*

DEBOOTSTRAP_MIRROR="http://deb.debian.org/debian"

echo "[INFO] Running debootstrap (stage 1)"
DEBIAN_FRONTEND=noninteractive debootstrap \
  --arch="${ARCH}" --foreign "${DISTRO}" "${ROOT}" "${DEBOOTSTRAP_MIRROR}"

install -D "${QEMU_BIN}" "${ROOT}${QEMU_BIN}"
install -D /etc/resolv.conf "${ROOT}/etc/resolv.conf"
if [ ! -f "${ROOT}/usr/share/keyrings/debian-archive-keyring.gpg" ] && [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
  install -D /usr/share/keyrings/debian-archive-keyring.gpg "${ROOT}/usr/share/keyrings/debian-archive-keyring.gpg"
fi

CHROOT_DIR="${ROOT}"
trap 'CHROOT_DIR="${ROOT}"; bind_mounts off; rm -f "${ROOT}${QEMU_BIN}"' EXIT
bind_mounts on

echo "[INFO] Running debootstrap (stage 2)"
chroot_qemu "/debootstrap/debootstrap --second-stage"

printf '%s\n' "${DEBIAN_SOURCES}" > "${ROOT}/etc/apt/sources.list"

chroot_qemu "DEBIAN_FRONTEND=noninteractive apt-get update"
if [ ! -f "${ROOT}/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
  chroot_qemu "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends debian-archive-keyring"
fi

chroot_qemu "DEBIAN_FRONTEND=noninteractive apt-get update"
chroot_qemu "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales openssh-server nftables xz-utils hostapd iw ca-certificates curl"

if [ -f "${ROOT}/etc/ssh/sshd_config" ]; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "${ROOT}/etc/ssh/sshd_config"
  if ! grep -q '^PermitRootLogin' "${ROOT}/etc/ssh/sshd_config"; then
    echo 'PermitRootLogin yes' >> "${ROOT}/etc/ssh/sshd_config"
  fi
fi
chroot_qemu "echo root:bananapi | chpasswd"

chroot_qemu "DEBIAN_FRONTEND=noninteractive locale-gen en_US.UTF-8"
cat > "${ROOT}/etc/default/locale" <<'LOCALE'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LOCALE

mkdir -p "${ROOT}/lib/firmware"
chroot_qemu "DEBIAN_FRONTEND=noninteractive apt-get clean"
rm -rf "${ROOT}/var/lib/apt/lists"/*

bind_mounts off
trap - EXIT
rm -f "${ROOT}${QEMU_BIN}"

GZIP=-n tar --sort=name --mtime='@0' --numeric-owner --owner=0 --group=0 -C "${ROOT}" -czf "${TAR}" .
sha256sum "${TAR}" > "${TAR}.sha256"

echo "[OK] Root filesystem tarball ready: ${TAR}"
