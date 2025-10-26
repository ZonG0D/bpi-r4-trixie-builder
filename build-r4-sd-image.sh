#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# build-r4-sd-image.sh  (quiet + debug-tail, BPI-R4 / MT7988A / 4GB DDR4)
#
# - U-Boot (BL33) mainline
# - TF-A (BL2+BL31) for BOOT_DEVICE=sdmmc
# - Auto-picks a board DT in TF-A fdts/ (mt7988a-bpi-r4.dts if present)
# - Supports EMI/DDR param blob via EMI_PARAM=...
# - BL2 @ LBA0, FIP @ LBA 2048; GPT p1 FAT32, p2 ext4
# - Quiet by default; verbose with VERBOSE=1
# -----------------------------------------------------------------------------

# ── Repos / refs ──────────────────────────────────────────────────────────────
: "${UBOOT_REMOTE:=https://source.denx.de/u-boot/u-boot.git}"
: "${UBOOT_REF:=master}"
: "${UBOOT_DEFCONFIG:=mt7988_sd_rfb_defconfig}"  # set to mt7988_bpi_r4_sd_defconfig if it appears upstream

: "${TFA_REMOTE:=https://github.com/mtk-openwrt/arm-trusted-firmware.git}"
: "${TFA_REF:=mtksoc}"
: "${BOOT_DEVICE:=sdmmc}"

# ── Toolchain / toggles ───────────────────────────────────────────────────────
: "${ARCH:=arm}"
: "${CROSS_COMPILE:=aarch64-linux-gnu-}"
: "${JOBS:=$(nproc)}"
: "${VERBOSE:=0}"        # 0=quiet, 1=chatty

# BPI-R4 is DDR4; add more flags via TFA_MAKEEXTRA=…
: "${TFA_LOG_LEVEL:=40}" # 50=ERROR, 40=INFO, 30=NOTICE, 20=WARNING, 10=VERBOSE
: "${TFA_MAKEEXTRA:=DRAM_USE_COMB=1 DRAM_DEBUG=1 LOG_LEVEL=${TFA_LOG_LEVEL}}"
: "${SDMMC_HEADER:=}"
: "${EMI_PARAM:=}"       # path to emi/DDR param blob if your TF-A expects it (optional)
: "${TFA_DTS:=auto}"     # auto-select board DT in fdts/; override e.g. TFA_DTS=mt7988a-bpi-r4.dts

# ── Image layout ──────────────────────────────────────────────────────────────
: "${IMG:=r4.img}"
: "${SIZE_MB:=1024}"
: "${BOOT_MB:=256}"
# reserved front area
ATF_START_LBA=34                # first usable LBA on GPT disks
ATF_END_LBA=2047                # ~1 MiB for BL2 image
FIP_START_LBA=2048              # 1 MiB
FIRST_PART_LBA=$((16*1024))     # 8 MiB for FAT32 boot


SECTOR=512
FIP_LBA=2048                 # 1 MiB
FIRST_PART_LBA=$((16*1024))  # 8 MiB

FIP_LBA=${FIP_START_LBA}

EFI_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"   # EFI System
LINUX_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4" # Linux filesystem

# ── Paths (runs from any dir) ─────────────────────────────────────────────────
ROOT="$(pwd -P)"
BUILD="${ROOT}/build-mt7988"
OUT="${BUILD}/out"
UBOOT_DIR="${BUILD}/u-boot"
TFA_DIR="${BUILD}/tfa"
mkdir -p "${BUILD}" "${OUT}"

MNT="$(mktemp -d -p "${BUILD}" mnt.XXXXXX)"
LOG="${BUILD}/build.log"; : > "${LOG}"

# ── Helpers ───────────────────────────────────────────────────────────────────
t0=0; now(){ date +%s; }; begin(){ t0=$(now); }; end(){ printf "  ↳ done in %ss\n" "$(( $(now)-t0 ))"; }
log(){ echo -e "$@" | tee -a "${LOG}" >/dev/null; }
say(){ echo -e "$@"; log "$@"; }
boring(){ echo -e "$@" >> "${LOG}"; }
fail_tail(){ echo; echo "✖ Failed: $*"; echo "─── Last 120 lines of ${LOG} ───"; tail -n 120 "${LOG}" || true; exit 1; }
run(){ if [[ "${VERBOSE}" -eq 1 ]]; then "$@" || fail_tail "$*"; else { "$@" >> "${LOG}" 2>&1; } || fail_tail "$*"; fi; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
cleanup(){ set +e; mountpoint -q "${MNT}" && sudo umount "${MNT}"; [[ -n "${LOOPDEV:-}" ]] && sudo losetup -d "${LOOPDEV}" >/dev/null 2>&1 || true; [[ -d "${MNT}" ]] && rmdir "${MNT}" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# ── Tool checks ───────────────────────────────────────────────────────────────
say "[check] host tools"
for t in git make dtc "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}ld" dd sfdisk partprobe losetup mkfs.vfat mkfs.ext4 mkimage sudo; do need "${t}"; done

# ── Prepare sources ───────────────────────────────────────────────────────────
begin
say "[1] Prepare sources"
run rm -rf "${UBOOT_DIR}" "${TFA_DIR}"
end

# ── Build U-Boot ──────────────────────────────────────────────────────────────
begin
say "[2] Build U-Boot (${UBOOT_REF} / ${UBOOT_DEFCONFIG})"
run git clone --depth=1 --branch "${UBOOT_REF}" "${UBOOT_REMOTE}" "${UBOOT_DIR}"
(
  cd "${UBOOT_DIR}"
  run env ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" make mrproper
  run env ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" make "${UBOOT_DEFCONFIG}"
  run env ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" make -j"${JOBS}"
  run install -m0644 u-boot.bin "${OUT}/u-boot.bin"
  [[ -f u-boot     ]] && run install -m0644 u-boot     "${OUT}/u-boot.elf" || true
  [[ -f u-boot.dtb ]] && run install -m0644 u-boot.dtb "${OUT}/u-boot.dtb" || true
)
end

# ── Build TF-A (BL2 + BL31 + FIP) ─────────────────────────────────────────────
begin
say "[3] Build TF-A (${TFA_REF}, PLAT=mt7988 BOOT_DEVICE=${BOOT_DEVICE})"
[[ -n "${EMI_PARAM}" ]] && TFA_MAKEEXTRA+=" EMI_PARAM=${EMI_PARAM}"
boring "TF-A flags: ${TFA_MAKEEXTRA}"
run git clone --depth=1 --branch "${TFA_REF}" "${TFA_REMOTE}" "${TFA_DIR}"
[[ -d "${TFA_DIR}/plat/mediatek/mt7988" ]] || { echo "TF-A tree missing plat/mediatek/mt7988"; exit 2; }
[[ -d "${TFA_DIR}/fdts" ]] || { echo "TF-A tree missing fdts/"; exit 2; }

# Auto-select a board DT if present
if [[ "${TFA_DTS}" == "auto" ]]; then
  # Try common BPI-R4 DT names (adjust list as needed)
  candidates=(
    "mt7988a-bpi-r4.dts"
    "mt7988-bpi-r4.dts"
    "mt7988a-bananapi-bpi-r4.dts"
    "mt7988-bananapi-bpi-r4.dts"
  )
  for d in "${candidates[@]}"; do
    if [[ -f "${TFA_DIR}/fdts/${d}" ]]; then TFA_DTS="${d}"; break; fi
  done
  # Fallback to generic
  [[ "${TFA_DTS}" == "auto" ]] && TFA_DTS="mt7988.dts"
fi
say "    • TF-A DT: ${TFA_DTS}"

(
  cd "${TFA_DIR}"
  # BL2/BL31/FIP with board DT
  run env CROSS_COMPILE="${CROSS_COMPILE}" make -j"${JOBS}" PLAT=mt7988 BOOT_DEVICE="${BOOT_DEVICE}" ${TFA_MAKEEXTRA} DTB_FILE_NAME="${TFA_DTS}" bl2
  run env CROSS_COMPILE="${CROSS_COMPILE}" make -j"${JOBS}" PLAT=mt7988 BOOT_DEVICE="${BOOT_DEVICE}" ${TFA_MAKEEXTRA} DTB_FILE_NAME="${TFA_DTS}" bl31
  run env CROSS_COMPILE="${CROSS_COMPILE}" make -j"${JOBS}" PLAT=mt7988 BOOT_DEVICE="${BOOT_DEVICE}" ${TFA_MAKEEXTRA} DTB_FILE_NAME="${TFA_DTS}" BL33="${OUT}/u-boot.bin" fip

  # Pick outputs
  if [[ -s build/mt7988/release/bl2.img ]]; then
    run install -m0644 build/mt7988/release/bl2.img "${OUT}/bl2.img"
  elif [[ -s build/mt7988/release/bl2.bin ]]; then
    run install -m0644 build/mt7988/release/bl2.bin "${OUT}/bl2.img"
  else
    fail_tail "BL2 missing"
  fi

  if   [[ -f build/mt7988/release/fip-${BOOT_DEVICE}.bin ]]; then
    run install -m0644 "build/mt7988/release/fip-${BOOT_DEVICE}.bin" "${OUT}/fip-sdmmc.bin"
  elif [[ -f build/mt7988/release/fip-sd.bin ]]; then
    run install -m0644 build/mt7988/release/fip-sd.bin "${OUT}/fip-sdmmc.bin"
  elif [[ -f build/mt7988/release/fip.bin ]]; then
    run install -m0644 build/mt7988/release/fip.bin "${OUT}/fip-sdmmc.bin"
  else
    fail_tail "FIP missing"
  fi
)
end

# ── Assemble image ────────────────────────────────────────────────────────────
begin
say "[4] Assemble image: ${IMG} (${SIZE_MB} MiB total, p1 ${BOOT_MB} MiB)"
run rm -f "${IMG}"
run truncate -s "${SIZE_MB}M" "${IMG}"

# Loop attach
LOOPDEV="$(sudo losetup --show -Pf "${IMG}")"
boring "loopdev: ${LOOPDEV}"

# Partition (portable sfdisk syntax with explicit nodes)
boot_size_sectors=$(( (BOOT_MB*1024*1024)/SECTOR ))
boot_start=${FIRST_PART_LBA}
boot_end=$(( boot_start + boot_size_sectors - 1 ))
p2_start=$((boot_end + 1))

boring "sfdisk: p1 start=${boot_start} size=${boot_size_sectors} type=${EFI_GUID}; p2 start=${p2_start} type=${LINUX_GUID}"

layout=$(printf "label: gpt\nunit: sectors\n\n%s : start=%d, size=%d, type=%s\n%s : start=%d, type=%s\n" \
  "${LOOPDEV}p1" "${boot_start}" "${boot_size_sectors}" "${EFI_GUID}" \
  "${LOOPDEV}p2" "${p2_start}" "${LINUX_GUID}")

echo "${layout}" | sudo sfdisk "${LOOPDEV}"

sudo partprobe "${LOOPDEV}" || true
sleep 1
say "    • mkfs FAT32 on p1 and ext4 on p2"
run sudo mkfs.vfat -F32 -n BPI_BOOT "${LOOPDEV}p1"
run sudo mkfs.ext4 -F -L BPI_ROOT "${LOOPDEV}p2"

# Loaders after partition creation
say "    • write BL2 @ LBA0 and FIP @ LBA ${FIP_LBA}"
run sudo dd if="${OUT}/bl2.img"       of="${IMG}" bs=${SECTOR} seek=0          conv=fsync,notrunc status=none
run sudo dd if="${OUT}/fip-sdmmc.bin" of="${IMG}" bs=${SECTOR} seek=${FIP_LBA} conv=fsync,notrunc status=none

# Sanity: SDMMC boot header present?
if ! dd if="${IMG}" bs=${SECTOR} count=1 status=none | head -c 12 | grep -q "SDMMC_BOOT"; then
  fail_tail "BL2 header check failed (SDMMC_BOOT not found at LBA0)"
fi

# Bootmenu to p1
say "    • install bootmenu to p1"
run sudo mount "${LOOPDEV}p1" "${MNT}"
cat > "${BUILD}/boot.txt" <<'EOS'
setenv bootdelay 0
setenv bootmenu_delay 0
setenv bootmenu_0 'Reboot=reset'
setenv bootmenu_1 'Power off=poweroff'
setenv bootmenu_2 'U-Boot shell=echo Entering shell; sleep 1;'
setenv bootmenu_3 'Continue distro boot=run distro_bootcmd'
bootmenu
EOS
run mkimage -A arm -T script -C none -n 'R4 bootmenu' -d "${BUILD}/boot.txt" "${BUILD}/boot.scr"
run sudo install -m0644 "${BUILD}/boot.scr" "${MNT}/boot.scr"
run sync
run sudo umount "${MNT}"
run sudo losetup -d "${LOOPDEV}"; unset LOOPDEV
end

say "[OK] Image ready: ${IMG}"
echo "# Flash it:"
echo "#   sudo dd if=${IMG} of=/dev/sdX bs=4M conv=fsync status=progress"
echo "# Verbose: VERBOSE=1 $0"
echo "# TF-A DT used: ${TFA_DTS}"
echo "# TF-A flags  : ${TFA_MAKEEXTRA}"
echo "# Full log    : ${LOG}"
