# Helper makefile for integrating the overlay into larger build systems.

UBOOT_OVERLAY_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
UBOOT_OVERLAY_PATCH := $(UBOOT_OVERLAY_DIR)/patches/0001-bpi-r4-board-and-config.patch

$(UBOOT_OVERLAY_PATCH):
@echo "Overlay patch missing: $@" >&2
@exit 1
