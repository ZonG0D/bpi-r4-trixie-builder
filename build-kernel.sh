#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
log_start "build-kernel"

check_bins git make tar gzip sha256sum aarch64-linux-gnu-gcc

KERNEL_TAG="v6.12-main"
KERNEL_SRC="${WORK_DIR}/kernel"
KERNEL_BUILD="${KERNEL_SRC}/build"
KERNEL_STAGE="${WORK_DIR}/kernel-stage"

mkdir -p "${KERNEL_SRC}" "${KERNEL_STAGE}"
rm -rf "${KERNEL_STAGE:?}"/*
rm -rf "${KERNEL_BUILD}"

if [ ! -d "${KERNEL_SRC}/.git" ]; then
    rm -rf "${KERNEL_SRC}"
    git clone --depth=1 --branch "${KERNEL_TAG}" \
        https://github.com/frank-w/BPI-Router-Linux "${KERNEL_SRC}"
else
    git -C "${KERNEL_SRC}" fetch --depth=1 origin "${KERNEL_TAG}"
    git -C "${KERNEL_SRC}" checkout "${KERNEL_TAG}"
fi

git -C "${KERNEL_SRC}" submodule update --init --recursive

make -C "${KERNEL_SRC}" O="${KERNEL_BUILD}" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- bpi-r4_defconfig
make -C "${KERNEL_SRC}" O="${KERNEL_BUILD}" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)"
make -C "${KERNEL_SRC}" O="${KERNEL_BUILD}" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="${KERNEL_STAGE}" modules_install

mkdir -p "${KERNEL_STAGE}/boot"
install -m 0644 "${KERNEL_BUILD}/arch/arm64/boot/Image" "${KERNEL_STAGE}/boot/Image"
find "${KERNEL_BUILD}/arch/arm64/boot/dts" -type f -name 'mt7988*.dtb' \
    -exec install -m 0644 {} "${KERNEL_STAGE}/boot/" \;

mkdir -p "${KERNEL_STAGE}$(dirname "${UBOOTCFG}")"
cat <<CFG > "${KERNEL_STAGE}${UBOOTCFG}"
bootargs=root=PARTUUID=%PARTUUID% rootfstype=ext4 rootwait rw console=ttyS0,115200n8
CFG

find "${KERNEL_STAGE}" -print0 | xargs -0 touch -h -d '@0'

KERNEL_TAR="${OUT_DIR}/${BOARD}_${KERNEL_TAG}.tar"
KERNEL_TAR_GZ="${KERNEL_TAR}.gz"
rm -f "${KERNEL_TAR}" "${KERNEL_TAR_GZ}"

tar --numeric-owner --owner=0 --group=0 --sort=name --mtime='@0' \
    -C "${KERNEL_STAGE}" -cf "${KERNEL_TAR}" .

gzip -n "${KERNEL_TAR}"
sha256sum "${KERNEL_TAR_GZ}" > "${KERNEL_TAR_GZ}.sha256"

echo "[OK] Kernel archive ready: ${KERNEL_TAR_GZ}"
