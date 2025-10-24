#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
log_start "build-uboot"

check_bins git make gzip sha256sum aarch64-linux-gnu-gcc

UBOOT_REF="main"
UBOOT_SRC="${WORK_DIR}/u-boot"
UBOOT_BUILD="${UBOOT_SRC}/build"

if [ ! -d "${UBOOT_SRC}/.git" ]; then
    rm -rf "${UBOOT_SRC}"
    git clone --depth=1 --branch "${UBOOT_REF}" \
        https://github.com/frank-w/u-boot "${UBOOT_SRC}"
else
    git -C "${UBOOT_SRC}" fetch --depth=1 origin "${UBOOT_REF}"
    git -C "${UBOOT_SRC}" checkout "${UBOOT_REF}"
fi

git -C "${UBOOT_SRC}" submodule update --init --recursive

rm -rf "${UBOOT_BUILD}"

make -C "${UBOOT_SRC}" O="${UBOOT_BUILD}" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- bpi-r4_defconfig
make -C "${UBOOT_SRC}" O="${UBOOT_BUILD}" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"

BOOT_IMG=""
for candidate in \
    "${UBOOT_BUILD}/bpi-r4_sdmmc.img" \
    "${UBOOT_BUILD}/u-boot-bpi-r4-sdmmc.img" \
    "${UBOOT_BUILD}/u-boot.bin"; do
    if [ -f "${candidate}" ]; then
        BOOT_IMG="${candidate}"
        break
    fi
done

if [ -z "${BOOT_IMG}" ]; then
    echo "[ERROR] Unable to locate generated SDMMC image" >&2
    exit 1
fi

OUTPUT_IMG="${OUT_DIR}/bpi-r4_trusted_sdmmc.img"
cp "${BOOT_IMG}" "${OUTPUT_IMG}"

gzip -n -f "${OUTPUT_IMG}"
FINAL_IMG="${OUT_DIR}/bpi-r4_sdmmc.img.gz"
mv "${OUTPUT_IMG}.gz" "${FINAL_IMG}"
sha256sum "${FINAL_IMG}" > "${FINAL_IMG}.sha256"

echo "[OK] U-Boot image ready: ${FINAL_IMG}"
