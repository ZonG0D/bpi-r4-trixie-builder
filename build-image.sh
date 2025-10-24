#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/r4-config.sh"

require_root
check_bins losetup parted partprobe mkfs.vfat mkfs.ext4 tar gzip sha256sum curl

UBOOT_BASE="${OUT_DIR}/bpi-r4_sdmmc.img.gz"
ROOTFS_TAR="${OUT_DIR}/${DISTRO}_${ARCH}.tar.gz"
KERNEL_TAR=$(ls "${OUT_DIR}"/bpi-r4_*main*.tar.gz 2>/dev/null | sort | tail -n1 || true)

[ -f "${UBOOT_BASE}" ] || fail "Missing U-Boot image at ${UBOOT_BASE}"
[ -f "${ROOTFS_TAR}" ] || fail "Missing rootfs tarball at ${ROOTFS_TAR}"
[ -n "${KERNEL_TAR}" ] || fail "Missing kernel bundle in ${OUT_DIR}"

FINAL_BASE="${OUT_DIR}/bpi-r4_trixie_${KERNEL}_sdmmc.img"
cp "${UBOOT_BASE}" "${FINAL_BASE}.gz"
gzip -df "${FINAL_BASE}.gz"

cleanup() {
  set +e
  if mountpoint -q mnt/BPI-ROOT; then umount mnt/BPI-ROOT; fi
  if mountpoint -q mnt/BPI-BOOT; then umount mnt/BPI-BOOT; fi
  if [ -n "${LDEV:-}" ]; then
    losetup -d "${LDEV}" >/dev/null 2>&1 || true
  fi
  set -e
}
trap cleanup EXIT

mkdir -p mnt/BPI-BOOT mnt/BPI-ROOT

LDEV=$(losetup --find --show "${FINAL_BASE}")
partprobe "${LDEV}"

mount "${LDEV}p${BOOT_PART}" mnt/BPI-BOOT
mount "${LDEV}p${ROOT_PART}" mnt/BPI-ROOT

tar --numeric-owner -xzf "${ROOTFS_TAR}" -C mnt/BPI-ROOT

tar --strip-components=1 -xzf "${KERNEL_TAR}" -C mnt/BPI-BOOT BPI-BOOT
mkdir -p mnt/BPI-ROOT/lib
tar --strip-components=2 -xzf "${KERNEL_TAR}" -C mnt/BPI-ROOT/lib BPI-ROOT/lib

mkdir -p mnt/BPI-ROOT/lib/firmware
if [ -d "${FIRMWARE_DIR}" ]; then
  cp -a "${FIRMWARE_DIR}/." mnt/BPI-ROOT/lib/firmware/
fi


mkdir -p mnt/BPI-ROOT/etc
cat > mnt/BPI-ROOT/etc/fstab <<EOF_FSTAB
/dev/mmcblk${MMCDEV}p${ROOT_PART} / ext4 defaults 0 1
/dev/mmcblk${MMCDEV}p${BOOT_PART} /boot vfat defaults 0 2
EOF_FSTAB

echo "bpi-r4" > mnt/BPI-ROOT/etc/hostname

mkdir -p "mnt/BPI-BOOT${UBOOTCFG_DIR}"
touch "mnt/BPI-BOOT${UBOOTCFG_FILE}"
if ! grep -q 'Customize kernel arguments' "mnt/BPI-BOOT${UBOOTCFG_FILE}" 2>/dev/null; then
cat <<UENV >> "mnt/BPI-BOOT${UBOOTCFG_FILE}"
# Customize kernel arguments below as needed
# bootopts=console=ttyS0,115200n8 root=/dev/mmcblk0p${ROOT_PART} rw
UENV
fi

cleanup
trap - EXIT
rmdir mnt/BPI-ROOT mnt/BPI-BOOT 2>/dev/null || true

gzip -n "${FINAL_BASE}"
FINAL_IMG="${FINAL_BASE}.gz"
sha256sum "${FINAL_IMG}" > "${FINAL_IMG}.sha256"

echo "[OK] Image ready: ${FINAL_IMG}"
