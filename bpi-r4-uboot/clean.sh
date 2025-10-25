#!/bin/bash
set -euo pipefail

UBOOT_SRC="${1:?path to u-boot source}"

if [ ! -d "${UBOOT_SRC}/.git" ]; then
  echo "Invalid U-Boot source at ${UBOOT_SRC}" >&2
  exit 1
fi

pushd "${UBOOT_SRC}" >/dev/null

git am --abort || true

git reset --hard
git clean -dfx

popd >/dev/null

rm -rf out dummy
