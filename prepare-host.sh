#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "[ERROR] This script must be run as root" >&2
  exit 1
fi

APT_PKGS=(
  binfmt-support
  ca-certificates
  curl
  debian-archive-keyring
  debootstrap
  jq
  kpartx
  p7zip-full
  qemu-user-static
  unzip
  xz-utils
)

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y "${APT_PKGS[@]}"

if command -v update-binfmts >/dev/null 2>&1; then
  if ! update-binfmts --display qemu-aarch64 2>/dev/null | grep -q "enabled"; then
    update-binfmts --enable qemu-aarch64 || true
  fi
  update-binfmts --display qemu-aarch64 || true
fi

QEMU_BIN="$(command -v qemu-aarch64-static || true)"
if [ -z "${QEMU_BIN}" ]; then
  echo "[ERROR] qemu-aarch64-static was not installed" >&2
  exit 1
fi

"${QEMU_BIN}" --version >/dev/null 2>&1 || {
  echo "[ERROR] Unable to execute ${QEMU_BIN}" >&2
  exit 1
}

echo "[INFO] Host dependencies installed and qemu-aarch64-static is ready."
echo "[INFO] You can now run 'sudo make image'."
