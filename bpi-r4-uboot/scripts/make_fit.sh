#!/bin/bash
set -euo pipefail
ITS="${1:?its}"
OUT="${2:?out itb}"
KERN="${3:?Image.gz}"
FDT="${4:?dtb}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

cp -f "${ITS}" "${TMP}/bpi-r4.its"
# token substitution
sed -i "s#__KERNEL__#${KERN}#g" "${TMP}/bpi-r4.its"
sed -i "s#__FDT__#${FDT}#g" "${TMP}/bpi-r4.its"

mkimage -f "${TMP}/bpi-r4.its" "${OUT}"
