#!/bin/bash
set -euo pipefail

BOARD=bpi-r4
ARCH=arm64
DISTRO=trixie
DEVICE=sdmmc
KERNEL=6.12
MMCDEV=0
BOOT_PART=5
ROOT_PART=6
QEMU_BIN=/usr/bin/qemu-aarch64-static
OUT_DIR="$(pwd)/out"
WORK_DIR="$(pwd)/work"
FIRMWARE_DIR="$(pwd)/firmware"
UBOOTCFG_DIR=/bananapi/bpi-r4/linux
UBOOTCFG_FILE="${UBOOTCFG_DIR}/uEnv.txt"

DEBIAN_SOURCES=$(cat <<'SRC'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
SRC
)

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run as root"
  fi
}

check_bins() {
  local missing=0
  for bin in "$@"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "[ERROR] Missing required command: $bin" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

__BIND_ACTIVE=0
bind_mounts() {
  local action="$1"
  if [ -z "${CHROOT_DIR:-}" ]; then
    fail "CHROOT_DIR is not set for bind_mounts"
  fi
  case "$action" in
    on)
      if [ "$__BIND_ACTIVE" -eq 1 ]; then
        return 0
      fi
      for dir in proc sys dev; do
        mkdir -p "${CHROOT_DIR}/${dir}"
      done
      mount -t proc proc "${CHROOT_DIR}/proc"
      mount -t sysfs sys "${CHROOT_DIR}/sys"
      mount --bind /dev "${CHROOT_DIR}/dev"
      __BIND_ACTIVE=1
      ;;
    off)
      if [ "$__BIND_ACTIVE" -eq 0 ]; then
        return 0
      fi
      for dir in dev sys proc; do
        if mountpoint -q "${CHROOT_DIR}/${dir}"; then
          umount "${CHROOT_DIR}/${dir}" || umount -l "${CHROOT_DIR}/${dir}" || true
        fi
      done
      __BIND_ACTIVE=0
      ;;
    *)
      fail "bind_mounts requires 'on' or 'off'"
      ;;
  esac
}

chroot_qemu() {
  if [ -z "${CHROOT_DIR:-}" ]; then
    fail "CHROOT_DIR is not set for chroot_qemu"
  fi
  local cmd="$1"
  chroot "${CHROOT_DIR}" "${QEMU_BIN}" /bin/sh -c "${cmd}"
}

mkdir -p "${OUT_DIR}" "${WORK_DIR}"
