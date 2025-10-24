#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
log_start "build-image"

check_bins parted losetup mkfs.ext4 tar gzip sha256sum rsync blkid dd zcat

ROOTFS_ARCHIVE="${OUT_DIR}/${DISTRO}_${ARCH}.tar.gz"
BOOTLOADER_ARCHIVE="${OUT_DIR}/bpi-r4_sdmmc.img.gz"
KERNEL_ARCHIVE="${KERNEL_ARCHIVE:-}"

if [ ! -f "${ROOTFS_ARCHIVE}" ]; then
    echo "[ERROR] Missing root filesystem archive: ${ROOTFS_ARCHIVE}" >&2
    exit 1
fi

if [ ! -f "${BOOTLOADER_ARCHIVE}" ]; then
    echo "[ERROR] Missing bootloader image: ${BOOTLOADER_ARCHIVE}" >&2
    exit 1
fi

if [ -z "${KERNEL_ARCHIVE}" ]; then
    KERNEL_ARCHIVE=$(find "${OUT_DIR}" -maxdepth 1 -type f -name "${BOARD}_*.tar.gz" | sort | head -n1 || true)
fi

if [ -z "${KERNEL_ARCHIVE}" ] || [ ! -f "${KERNEL_ARCHIVE}" ]; then
    echo "[ERROR] Missing kernel archive in ${OUT_DIR}" >&2
    exit 1
fi

IMAGE_RAW="${OUT_DIR}/${BOARD}_${DISTRO}_${KERNEL}_${DEVICE}.img"
IMAGE_GZ="${IMAGE_RAW}.gz"
IMAGE_SIZE=${IMAGE_SIZE:-4096}

rm -f "${IMAGE_RAW}" "${IMAGE_GZ}"
truncate -s "${IMAGE_SIZE}M" "${IMAGE_RAW}"

LOOPDEV=$(losetup --show --find "${IMAGE_RAW}")

cleanup() {
    set +e
    if mountpoint -q "${WORK_DIR}/mnt/boot"; then
        umount "${WORK_DIR}/mnt/boot"
    fi
    if mountpoint -q "${WORK_DIR}/mnt/root"; then
        umount "${WORK_DIR}/mnt/root"
    fi
    if [ -n "${LOOPDEV}" ]; then
        losetup -d "${LOOPDEV}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

zcat "${BOOTLOADER_ARCHIVE}" | dd of="${LOOPDEV}" bs=512 conv=notrunc oflag=direct status=none

parted -s "${LOOPDEV}" mklabel gpt
parted -s "${LOOPDEV}" unit MiB mkpart loader1 0.5 2
parted -s "${LOOPDEV}" unit MiB mkpart loader2 2 4
parted -s "${LOOPDEV}" unit MiB mkpart env 4 6
parted -s "${LOOPDEV}" unit MiB mkpart reserved 6 8
parted -s "${LOOPDEV}" unit MiB mkpart boot 8 264
parted -s "${LOOPDEV}" unit MiB mkpart root 264 100%
parted -s "${LOOPDEV}" print

partprobe "${LOOPDEV}"

BOOT_PART="${LOOPDEV}p${BOOT_PARTITION}"
ROOT_PART="${LOOPDEV}p${ROOT_PARTITION}"

mkfs.ext4 -F -L BPI-BOOT "${BOOT_PART}"
mkfs.ext4 -F -L BPI-ROOT "${ROOT_PART}"

mkdir -p "${WORK_DIR}/mnt/boot" "${WORK_DIR}/mnt/root"
mount "${BOOT_PART}" "${WORK_DIR}/mnt/boot"
mount "${ROOT_PART}" "${WORK_DIR}/mnt/root"

ROOT_MNT="${WORK_DIR}/mnt/root"
BOOT_MNT="${WORK_DIR}/mnt/boot"

mkdir -p "${WORK_DIR}/kernel-extract"
rm -rf "${WORK_DIR}/kernel-extract"/*

tar --same-owner --numeric-owner -xzf "${ROOTFS_ARCHIVE}" -C "${ROOT_MNT}"

tar --same-owner --numeric-owner -xzf "${KERNEL_ARCHIVE}" -C "${WORK_DIR}/kernel-extract"

if [ -d "${WORK_DIR}/kernel-extract/lib" ]; then
    rsync -a "${WORK_DIR}/kernel-extract/lib/" "${ROOT_MNT}/lib/"
fi
if [ -d "${WORK_DIR}/kernel-extract/boot" ]; then
    rsync -a "${WORK_DIR}/kernel-extract/boot/" "${BOOT_MNT}/"
fi
if [ -d "${WORK_DIR}/kernel-extract/bananapi" ]; then
    rsync -a "${WORK_DIR}/kernel-extract/bananapi/" "${BOOT_MNT}/bananapi/"
fi

mkdir -p "${ROOT_MNT}/lib/firmware"
if [ -d "${FIRMWARE_DIR}" ] && find "${FIRMWARE_DIR}" -mindepth 1 -print -quit >/dev/null 2>&1; then
    rsync -a "${FIRMWARE_DIR}/" "${ROOT_MNT}/lib/firmware/"
fi

PARTUUID_BOOT=$(blkid -s PARTUUID -o value "${BOOT_PART}")
PARTUUID_ROOT=$(blkid -s PARTUUID -o value "${ROOT_PART}")

cat <<FSTAB > "${ROOT_MNT}/etc/fstab"
PARTUUID=${PARTUUID_ROOT}  /      ext4  defaults,noatime  0 1
PARTUUID=${PARTUUID_BOOT}  /boot  ext4  defaults,noatime  0 2
proc    /proc   proc    defaults    0 0
FSTAB

echo "${BOARD}" > "${ROOT_MNT}/etc/hostname"

UBOOT_FILE="${BOOT_MNT}${UBOOTCFG}"
if [ -f "${UBOOT_FILE}" ]; then
    sed -i "s/%PARTUUID%/${PARTUUID_ROOT}/g" "${UBOOT_FILE}"
fi

find "${ROOT_MNT}" -print0 | xargs -0 touch -h -d '@0'
find "${BOOT_MNT}" -print0 | xargs -0 touch -h -d '@0'

sync

umount "${BOOT_MNT}"
umount "${ROOT_MNT}"
losetup -d "${LOOPDEV}"
LOOPDEV=""
rm -rf "${WORK_DIR}/kernel-extract"

gzip -n "${IMAGE_RAW}"
sha256sum "${IMAGE_GZ}" > "${IMAGE_GZ}.sha256"

echo "[OK] Image ready: ${IMAGE_GZ}"
