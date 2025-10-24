# Banana Pi R4 Trixie Builder

OUT        := out
ROOTFS_TAR := $(OUT)/trixie_arm64.tar.gz
IMG        := $(OUT)/bpi-r4_trixie_6.12_sdmmc.img.gz

.PHONY: all fetch local clean

all: fetch

fetch: ## Download prebuilt kernel, bootloader, and firmware, then build image
	@echo "==> Fetching assets for BPI-R4 (Debian Trixie)"
	@mkdir -p $(OUT)
	@python3 fetch-assets.py bpi-r4 6.12 sdmmc
	@bash rootfs-build.sh
	@bash image-build.sh
	@echo "==> Image ready: $(IMG)"

local: ## Build kernel + u-boot locally, then assemble image
	@echo "==> Building local assets for BPI-R4"
	@mkdir -p $(OUT)
	@bash build-uboot.sh
	@bash build-kernel.sh
	@bash rootfs-build.sh
	@bash image-build.sh
	@echo "==> Local image ready: $(IMG)"

clean: ## Remove all build artifacts
	@echo "==> Cleaning output directory"
	@rm -rf $(OUT)/*
