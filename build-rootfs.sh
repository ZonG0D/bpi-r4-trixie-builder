#!/bin/bash
set -euo pipefail

. "$(dirname "$0")/r4-config.sh"

require_root
log_start "build-rootfs"

check_bins tar gzip sha256sum rsync
# Detect available bootstrapping tools.
if command -v mmdebstrap >/dev/null 2>&1; then
    HAVE_MMDEBSTRAP=1
else
    HAVE_MMDEBSTRAP=0
fi
if command -v debootstrap >/dev/null 2>&1; then
    HAVE_DEBOOTSTRAP=1
else
    HAVE_DEBOOTSTRAP=0
fi
if [ "${HAVE_MMDEBSTRAP}" -eq 0 ] && [ "${HAVE_DEBOOTSTRAP}" -eq 0 ]; then
    echo "[ERROR] Neither mmdebstrap nor debootstrap found" >&2
    exit 1
fi

ROOTFS_DIR="${WORK_DIR}/rootfs"
mkdir -p "${ROOTFS_DIR}"
rm -rf "${ROOTFS_DIR:?}"/*

if [ ! -x "${QEMU_BIN}" ]; then
    echo "[ERROR] QEMU binary not found at ${QEMU_BIN}" >&2
    echo "[HINT] Install qemu-user-static and systemd-binfmt or binfmt-support" >&2
    exit 1
fi

can_mount() {
    if unshare -m true >/dev/null 2>&1; then
        return 0
    fi
    local t1 t2 rc=1
    t1="$(mktemp -d)"; t2="$(mktemp -d)"
    if mount --bind "$t1" "$t2" >/dev/null 2>&1; then
        umount "$t2" || true
        rc=0
    fi
    rmdir "$t1" "$t2" || true
    return $rc
}

if can_mount; then
    CAN_MOUNT=1
else
    CAN_MOUNT=0
fi

can_unshare_mount() {
    if ! command -v unshare >/dev/null 2>&1; then
        return 1
    fi
    if unshare -Ur --map-root-user --map-auto --mount --propagation unchanged true \
        >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

if can_unshare_mount; then
    CAN_UNSHARE_MOUNT=1
else
    CAN_UNSHARE_MOUNT=0
fi

ensure_qemu_binfmt() {
    if [ ! -d /proc/sys/fs/binfmt_misc ]; then
        return
    fi
    if [ ! -f /proc/sys/fs/binfmt_misc/register ]; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc >/dev/null 2>&1 || return
    fi
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        if [ -w /proc/sys/fs/binfmt_misc/register ]; then
            cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
        fi
    fi
}

DEBOOTSTRAP_LOG="${LOG_DIR}/debootstrap.log"

if [ "${HAVE_MMDEBSTRAP}" -eq 1 ] && [ "${CAN_MOUNT}" -eq 0 ]; then
    if [ "${CAN_UNSHARE_MOUNT}" -eq 0 ]; then
        echo "[ERROR] mmdebstrap requires unshare but user namespaces are unavailable" >&2
        exit 1
    fi
    echo "[INFO] Using mmdebstrap under unshare. Container has no mount capability."
    check_bins mmdebstrap unshare newuidmap newgidmap
    ensure_subid_mapping() {
        local entry user="$1" file="$2"
        entry="${user}:100000:65536"
        if ! grep -q "^${user}:" "${file}" 2>/dev/null; then
            echo "${entry}" >>"${file}"
        fi
    }
    ensure_subid_mapping root /etc/subuid
    ensure_subid_mapping root /etc/subgid
    MMDEBSTRAP_COMMON=(
        --mode=root
        --skip=check/qemu
        --architectures="${ARCH}"
        --variant=minbase
        --components="main,contrib,non-free-firmware"
        --include="locales,openssh-server,nftables,xz-utils,hostapd,iw,ca-certificates,net-tools"
        --aptopt='Acquire::Languages "none"'
        --aptopt='APT::Install-Recommends "0"'
        --setup-hook='mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true'
        --setup-hook='if [ -w /proc/sys/fs/binfmt_misc/register ]; then cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register || true; fi'
    )
    DEBIAN_FRONTEND=noninteractive unshare -Ur --map-root-user --map-auto --mount --propagation unchanged \
        mmdebstrap "${MMDEBSTRAP_COMMON[@]}" \
        "${DISTRO}" "${ROOTFS_DIR}" "${MIRROR_MAIN}" >>"${DEBOOTSTRAP_LOG}" 2>&1
else
    check_bins debootstrap chroot
    if [ "${HAVE_DEBOOTSTRAP}" -eq 0 ]; then
        echo "[ERROR] debootstrap not available and mmdebstrap path not selected" >&2
        exit 1
    fi
    echo "[INFO] Running debootstrap (stage 1)"
    DEBIAN_FRONTEND=noninteractive debootstrap \
        --arch="${ARCH}" --foreign --variant=minbase \
        "${DISTRO}" "${ROOTFS_DIR}" "${MIRROR_MAIN}" \
        >>"${DEBOOTSTRAP_LOG}" 2>&1
fi

cp "${QEMU_BIN}" "${ROOTFS_DIR}${QEMU_BIN}"

mount_chroot() {
    for dir in proc sys dev dev/pts; do
        mkdir -p "${ROOTFS_DIR}/${dir}"
    done
    mount -t proc /proc "${ROOTFS_DIR}/proc"
    mount --rbind /sys "${ROOTFS_DIR}/sys"
    mount --make-rslave "${ROOTFS_DIR}/sys"
    mount --rbind /dev "${ROOTFS_DIR}/dev"
    mount --make-rslave "${ROOTFS_DIR}/dev"
    mount --rbind /dev/pts "${ROOTFS_DIR}/dev/pts"
}

umount_chroot() {
    for dir in dev/pts dev sys proc; do
        if mountpoint -q "${ROOTFS_DIR}/${dir}"; then
            umount -R "${ROOTFS_DIR}/${dir}"
        fi
    done
}

cleanup() {
    umount_chroot || true
}

trap cleanup EXIT

if [ "${HAVE_MMDEBSTRAP}" -eq 1 ] && [ "${CAN_MOUNT}" -eq 0 ]; then
    echo "[INFO] Skipping debootstrap stage 2; mmdebstrap produced complete rootfs."
else
    ensure_qemu_binfmt
    mount_chroot
    echo "[INFO] Running debootstrap (stage 2)"
    chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage
fi

mkdir -p "${ROOTFS_DIR}/etc/apt"
mkdir -p "${ROOTFS_DIR}/etc/apt/apt.conf.d"
cat <<SOURCES > "${ROOTFS_DIR}/etc/apt/sources.list"
${DEBIAN_SOURCES}
SOURCES

echo 'Acquire::Languages "none";' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99nolanguages"
echo 'APT::Install-Recommends "0";' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99norecommends"

if [ "${HAVE_MMDEBSTRAP}" -eq 1 ] && [ "${CAN_MOUNT}" -eq 0 ]; then
    :
else
    echo "[INFO] Configuring locale"
    chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get update
    chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y locales openssh-server nftables xz-utils hostapd iw
    chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends ca-certificates net-tools

    chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
        apt-get clean
fi

rm -rf "${ROOTFS_DIR}/var/lib/apt/lists"/* "${ROOTFS_DIR}/var/cache/apt/archives"/* || true

mkdir -p "${ROOTFS_DIR}/etc"
printf 'LANG=en_US.UTF-8\n' > "${ROOTFS_DIR}/etc/default/locale"
if [ -f "${ROOTFS_DIR}/usr/sbin/locale-gen" ]; then
    chroot "${ROOTFS_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive locale-gen en_US.UTF-8 || true
fi

SSH_CONFIG="${ROOTFS_DIR}/etc/ssh/sshd_config"
mkdir -p "$(dirname "${SSH_CONFIG}")"
touch "${SSH_CONFIG}"
if grep -q '^PermitRootLogin' "${SSH_CONFIG}"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "${SSH_CONFIG}"
else
    printf '\nPermitRootLogin yes\n' >> "${SSH_CONFIG}"
fi

ROOT_PASS_HASH='$6$v/YEXbsZz2bQUAnd$2jiguIHl8KCLKSxcJ3GX7rqjjnEthpHmedKQ1Xyto3qaQ4IB5/dFK8TlXISkcNgJKXoaXiL.hekFR1jymch67.'
SHADOW_FILE="${ROOTFS_DIR}/etc/shadow"
if [ -f "${SHADOW_FILE}" ]; then
    awk -F: -v hash="${ROOT_PASS_HASH}" 'BEGIN{OFS=":"} $1=="root" {$2=hash} {print}' "${SHADOW_FILE}" > "${SHADOW_FILE}.tmp"
    mv "${SHADOW_FILE}.tmp" "${SHADOW_FILE}"
else
    printf 'root:%s:19500:0:99999:7:::\n' "${ROOT_PASS_HASH}" > "${SHADOW_FILE}"
fi

mkdir -p "${ROOTFS_DIR}/etc/network/interfaces.d"
mkdir -p "${ROOTFS_DIR}/etc/hostapd"
install -m 0644 "${CONF_DIR}/interfaces" "${ROOTFS_DIR}/etc/network/interfaces.d/bpi-r4"
install -m 0644 "${CONF_DIR}/hostapd.conf" "${ROOTFS_DIR}/etc/hostapd/hostapd.conf"
mkdir -p "${ROOTFS_DIR}/etc/nftables.conf.d"
install -m 0644 "${CONF_DIR}/nftables.nft" "${ROOTFS_DIR}/etc/nftables.conf.d/bpi-r4.nft"

cat <<'HOSTAPD' > "${ROOTFS_DIR}/etc/default/hostapd"
DAEMON_CONF="/etc/hostapd/hostapd.conf"
DAEMON_OPTS=""
HOSTAPD

cat <<'NFTMAIN' > "${ROOTFS_DIR}/etc/nftables.conf"
include "/etc/nftables.conf.d/bpi-r4.nft"
NFTMAIN

mkdir -p "${ROOTFS_DIR}/usr/local/sbin"
install -m 0755 "${CONF_DIR}/wifi-check.sh" "${ROOTFS_DIR}/usr/local/sbin/wifi-check.sh"
install -m 0644 "${CONF_DIR}/wifi-check.service" "${ROOTFS_DIR}/etc/systemd/system/wifi-check.service"

mkdir -p "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/ssh.service "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/ssh.service"
ln -sf /lib/systemd/system/hostapd.service "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/hostapd.service"
ln -sf /lib/systemd/system/nftables.service "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/nftables.service"
ln -sf /etc/systemd/system/wifi-check.service "${ROOTFS_DIR}/etc/systemd/system/multi-user.target.wants/wifi-check.service"

echo "${BOARD}" > "${ROOTFS_DIR}/etc/hostname"

rm -f "${ROOTFS_DIR}/etc/ssh/ssh_host_"*

cat <<'HOSTS' > "${ROOTFS_DIR}/etc/hosts"
127.0.0.1   localhost
127.0.1.1   bpi-r4

# IPv6 defaults
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS

if [ -d "${FIRMWARE_DIR}" ] && find "${FIRMWARE_DIR}" -mindepth 1 -print -quit >/dev/null 2>&1; then
    echo "[INFO] Copying firmware blobs"
    rsync -a "${FIRMWARE_DIR}/" "${ROOTFS_DIR}/lib/firmware/"
fi

rm -f "${ROOTFS_DIR}${QEMU_BIN}"

if [ "${CAN_MOUNT}" -eq 1 ]; then
    umount_chroot || true
    trap - EXIT
fi

find "${ROOTFS_DIR}" -print0 | xargs -0 touch -h -d '@0'

mkdir -p "${OUT_DIR}"
ROOTFS_TAR="${OUT_DIR}/${DISTRO}_${ARCH}.tar"
ROOTFS_TAR_GZ="${ROOTFS_TAR}.gz"

rm -f "${ROOTFS_TAR}" "${ROOTFS_TAR_GZ}"

tar --numeric-owner --owner=0 --group=0 --sort=name --mtime='@0' \
    -C "${ROOTFS_DIR}" -cf "${ROOTFS_TAR}" .

gzip -n "${ROOTFS_TAR}"

sha256sum "${ROOTFS_TAR_GZ}" > "${ROOTFS_TAR_GZ}.sha256"

echo "[OK] Root filesystem ready: ${ROOTFS_TAR_GZ}"
