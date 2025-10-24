#!/bin/bash
set -euo pipefail

BOARD="bpi-r4"
ARCH="arm64"
DISTRO="trixie"
DEVICE="sdmmc"
KERNEL="6.12"
BOOT_PARTITION=5
ROOT_PARTITION=6

MIRROR_MAIN="http://deb.debian.org/debian"
MIRROR_SECURITY="http://security.debian.org/debian-security"
MIRROR_UPDATES="http://deb.debian.org/debian"

DEBIAN_SOURCES="deb ${MIRROR_MAIN} ${DISTRO} main contrib non-free non-free-firmware\n\
deb ${MIRROR_SECURITY} ${DISTRO}-security main contrib non-free non-free-firmware\n\
deb ${MIRROR_UPDATES} ${DISTRO}-updates main contrib non-free non-free-firmware"

UBOOTCFG="/bananapi/bpi-r4/linux/uEnv.txt"
QEMU_BIN="/usr/bin/qemu-aarch64-static"

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT_DIR="${PROJECT_ROOT}/out"
LOG_DIR="${OUT_DIR}/logs"
WORK_DIR="${PROJECT_ROOT}/work"
FIRMWARE_DIR="${PROJECT_ROOT}/firmware"
CONF_DIR="${PROJECT_ROOT}/conf"

mkdir -p "${OUT_DIR}" "${LOG_DIR}" "${WORK_DIR}" "${FIRMWARE_DIR}"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] This script must be run as root." >&2
        exit 1
    fi
}

log_start() {
    local name="$1"
    local logfile="${LOG_DIR}/${name}.log"
    mkdir -p "${LOG_DIR}"
    exec > >(tee -a "${logfile}") 2>&1
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

