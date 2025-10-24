SHELL := /bin/bash
MAKEFLAGS += --warn-undefined-variables

CONFIG := $(CURDIR)/r4-config.sh
OUT_DIR := $(shell bash -c '. $(CONFIG) >/dev/null 2>&1; echo $$OUT_DIR')

.DEFAULT_GOAL := fetch

.PHONY: fetch local clean assets rootfs kernel uboot image bootstrap

fetch:
	@set -euo pipefail; ./bootstrap.sh
	@set -euo pipefail; ./fetch-assets.py
	@set -euo pipefail; ./build-rootfs.sh
	@set -euo pipefail; KERNEL_ARCHIVE="$(OUT_DIR)/bpi-r4_6.17.0-main.tar.gz" ./build-image.sh

local:
	@set -euo pipefail; ./bootstrap.sh
	@set -euo pipefail; ./fetch-assets.py kernel_firmware
	@set -euo pipefail; ./build-uboot.sh
	@set -euo pipefail; ./build-kernel.sh
	@set -euo pipefail; ./build-rootfs.sh
	@set -euo pipefail; KERNEL_ARCHIVE="$(OUT_DIR)/bpi-r4_v6.12-main.tar.gz" ./build-image.sh

clean:
	@set -euo pipefail; \
	if mountpoint -q "$(CURDIR)/work/mnt/boot"; then umount "$(CURDIR)/work/mnt/boot"; fi; \
	if mountpoint -q "$(CURDIR)/work/mnt/root"; then umount "$(CURDIR)/work/mnt/root"; fi; \
	rm -rf "$(CURDIR)/out" "$(CURDIR)/work"
