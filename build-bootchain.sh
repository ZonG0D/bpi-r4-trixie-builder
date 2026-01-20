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

check_bins git make "${CROSS_COMPILE}gcc"

SRC_DIR="${WORK_DIR}/src"
BUILD_DIR="${WORK_DIR}/build"
mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${OUT_BL2_DIR}" "${OUT_TFA_DIR}" "${OUT_UBOOT_DIR}"

sync_repo() {
  local name="$1"
  local repo="$2"
  local ref="$3"
  local dest="$4"

  if [ -z "${repo}" ]; then
    fail "${name} repo is not set"
  fi
  if [ ! -d "${dest}/.git" ]; then
    git clone "${repo}" "${dest}"
  fi
  git -C "${dest}" fetch --tags origin
  if [ -n "${ref}" ]; then
    git -C "${dest}" checkout "${ref}"
  fi
  git -C "${dest}" submodule update --init --recursive
}

copy_outputs() {
  local name="$1"
  local src_root="$2"
  local build_root="$3"
  local out_dir="$4"
  shift 4
  local outputs=("$@")

  if [ "${#outputs[@]}" -eq 0 ]; then
    fail "${name} outputs are not configured"
  fi

  for output in "${outputs[@]}"; do
    local source_path=""
    if [ -z "${output}" ]; then
      continue
    fi
    if [ -e "${build_root}/${output}" ]; then
      source_path="${build_root}/${output}"
    elif [ -e "${src_root}/${output}" ]; then
      source_path="${src_root}/${output}"
    elif [ -e "${output}" ]; then
      source_path="${output}"
    else
      fail "${name} output not found: ${output}"
    fi
    cp -a "${source_path}" "${out_dir}/"
  done
}

build_component() {
  local name="$1"
  local repo="$2"
  local ref="$3"
  local src_dir="$4"
  local build_dir="$5"
  local build_cmd="$6"
  local out_dir="$7"
  shift 7
  local outputs=("$@")

  if [ -z "${build_cmd}" ]; then
    fail "${name} build command is not configured"
  fi

  sync_repo "${name}" "${repo}" "${ref}" "${src_dir}"
  mkdir -p "${build_dir}" "${out_dir}"

  echo "[INFO] Building ${name}"
  (
    cd "${src_dir}"
    BUILD_DIR="${build_dir}" \
    OUT_DIR="${out_dir}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    JOBS="${JOBS}" \
    bash -c "${build_cmd}"
  )

  copy_outputs "${name}" "${src_dir}" "${build_dir}" "${out_dir}" "${outputs[@]}"
}

if [ "${SKIP_BL2}" -eq 1 ]; then
  echo "[SKIP] BL2 / Preloader"
else
  build_component "BL2" "${BL2_REPO}" "${BL2_REF}" \
    "${SRC_DIR}/bl2" "${BUILD_DIR}/bl2" "${BL2_BUILD_CMD}" "${OUT_BL2_DIR}" \
    "${BL2_OUTPUTS[@]}"
fi

build_component "TF-A" "${TF_A_REPO}" "${TF_A_REF}" \
  "${SRC_DIR}/tf-a" "${BUILD_DIR}/tf-a" "${TF_A_BUILD_CMD}" "${OUT_TFA_DIR}" \
  "${TF_A_OUTPUTS[@]}"

build_component "U-Boot" "${UBOOT_REPO}" "${UBOOT_REF}" \
  "${SRC_DIR}/u-boot" "${BUILD_DIR}/u-boot" "${UBOOT_BUILD_CMD}" "${OUT_UBOOT_DIR}" \
  "${UBOOT_OUTPUTS[@]}"

if [ -n "${UBOOT_IMAGE_NAME:-}" ]; then
  if [ -f "${OUT_UBOOT_DIR}/${UBOOT_IMAGE_NAME}" ]; then
    echo "[OK] U-Boot image staged at ${OUT_UBOOT_DIR}/${UBOOT_IMAGE_NAME}"
  fi
fi
