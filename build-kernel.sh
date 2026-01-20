#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/r4-config.sh"

BOOTCHAIN_CONFIG="${BOOTCHAIN_CONFIG:-${SCRIPT_DIR}/conf/bootchain.env}"
if [ -f "${BOOTCHAIN_CONFIG}" ]; then
  . "${BOOTCHAIN_CONFIG}"
else
  fail "Missing bootchain config at ${BOOTCHAIN_CONFIG}"
fi

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

check_bins git make "${CROSS_COMPILE}gcc" bc bison flex dtc

SRC_DIR="${WORK_DIR}/src/linux"
BUILD_DIR="${WORK_DIR}/build/kernel"
STAGING_DIR="${WORK_DIR}/staging/kernel"

mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${STAGING_DIR}" "${OUT_KERNEL_DIR}"

if [ ! -d "${SRC_DIR}/.git" ]; then
  if [ -z "${KERNEL_REPO}" ]; then
    fail "KERNEL_REPO is not set"
  fi
  git clone "${KERNEL_REPO}" "${SRC_DIR}"
fi

if [ -n "${KERNEL_REF}" ]; then
  git -C "${SRC_DIR}" fetch --tags origin
  git -C "${SRC_DIR}" checkout "${KERNEL_REF}"
fi

git -C "${SRC_DIR}" submodule update --init --recursive

if [ -z "${KERNEL_DEFCONFIG}" ]; then
  fail "KERNEL_DEFCONFIG is not set"
fi

ARCH=arm64

make -C "${SRC_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" \
  O="${BUILD_DIR}" "${KERNEL_DEFCONFIG}"

make -C "${SRC_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" \
  O="${BUILD_DIR}" -j"${JOBS}" Image modules dtbs

mkdir -p "${STAGING_DIR}/BPI-BOOT" "${STAGING_DIR}/BPI-ROOT/lib"

if [ -f "${BUILD_DIR}/arch/arm64/boot/Image" ]; then
  cp -a "${BUILD_DIR}/arch/arm64/boot/Image" "${STAGING_DIR}/BPI-BOOT/"
else
  fail "Kernel Image not found"
fi

if [ -n "${KERNEL_DTB}" ]; then
  DTB_PATH="${BUILD_DIR}/arch/arm64/boot/dts/${KERNEL_DTB}"
  if [ -f "${DTB_PATH}" ]; then
    mkdir -p "${STAGING_DIR}/BPI-BOOT/$(dirname "${KERNEL_DTB}")"
    cp -a "${DTB_PATH}" "${STAGING_DIR}/BPI-BOOT/${KERNEL_DTB}"
  else
    fail "Kernel DTB not found: ${DTB_PATH}"
  fi
fi

make -C "${SRC_DIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" \
  O="${BUILD_DIR}" INSTALL_MOD_PATH="${STAGING_DIR}/BPI-ROOT" \
  modules_install

KERNEL_TAR_NAME="${KERNEL_TAR_NAME:-bpi-r4_kernel.tar.gz}"
KERNEL_TAR_PATH="${OUT_KERNEL_DIR}/${KERNEL_TAR_NAME}"

rm -f "${KERNEL_TAR_PATH}"

(
  cd "${STAGING_DIR}"
  tar -czf "${KERNEL_TAR_PATH}" BPI-BOOT BPI-ROOT/lib
)

sha256sum "${KERNEL_TAR_PATH}" > "${KERNEL_TAR_PATH}.sha256"

echo "[OK] Kernel bundle ready: ${KERNEL_TAR_PATH}"
