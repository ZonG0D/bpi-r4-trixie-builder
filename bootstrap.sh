#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root

REQUIRED_PACKAGES=(
    debootstrap qemu-user-static binfmt-support parted python3 python3-requests curl rsync
    xz-utils gzip tar build-essential ca-certificates git
)
OPTIONAL_PACKAGES=(
    gcc-aarch64-linux-gnu bc flex bison libssl-dev libncurses5-dev
)

dpkg_query() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg_query "$pkg"; then
        missing+=("$pkg")
    fi
done

if [ ${#missing[@]} -ne 0 ]; then
    echo "[INFO] Installing required packages: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

missing_opt=()
for pkg in "${OPTIONAL_PACKAGES[@]}"; do
    if ! dpkg_query "$pkg"; then
        missing_opt+=("$pkg")
    fi
done

if [ ${#missing_opt[@]} -ne 0 ]; then
    echo "[INFO] Optional cross-build packages missing: ${missing_opt[*]}"
    echo "       Install with: sudo apt-get install ${missing_opt[*]}" >&2
fi

check_bins curl python3 debootstrap tar gzip xz cat

echo "[OK] Host dependencies verified."
