#!/bin/bash
set -euo pipefail

UBOOT_SRC="${1:?path to u-boot source}"
UBOOT_REF="${2:-v2025.10}"

WORK="$(pwd)"
OUT="${WORK}/out"
PATCHES="${WORK}/patches"

mkdir -p "${OUT}"

if [ ! -d "${UBOOT_SRC}/.git" ]; then
  echo "Invalid U-Boot source at ${UBOOT_SRC}" >&2
  exit 1
fi

if [ ! -f "${PATCHES}/0001-bpi-r4-board-and-config.patch" ]; then
  echo "Missing overlay patch" >&2
  exit 1
fi

# ensure toolchain configuration is loaded
if [ -f "${WORK}/toolchain.mk" ]; then
  # shellcheck disable=SC1090
  source "${WORK}/toolchain.mk"
fi

export ARCH=arm
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

pushd "${UBOOT_SRC}" >/dev/null

git fetch --tags
git checkout -f "${UBOOT_REF}"

git reset --hard
git clean -dfx

git am "${PATCHES}/0001-bpi-r4-board-and-config.patch"

make mrproper
make bpi_r4_defconfig
make -j"$(nproc)"

cp -av u-boot.bin "${OUT}/"
if [ -f u-boot-with-spl.bin ]; then
  cp -av u-boot-with-spl.bin "${OUT}/"
fi

popd >/dev/null

# optional: generate kernel FIT for SD boot sanity
kernel="${WORK}/dummy/Image.gz"
dtb="${WORK}/dummy/mt7988a-bananapi-bpi-r4.dtb"
mkdir -p "$(dirname "${kernel}")"
: > "${kernel}"
: > "${dtb}"
"${WORK}/scripts/make_fit.sh" its/bpi-r4.its "${OUT}/bpi-r4.itb" "${kernel}" "${dtb}"
