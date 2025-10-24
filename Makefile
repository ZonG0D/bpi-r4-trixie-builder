SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: all fetch rootfs image clean

all: image

fetch:
	./fetch-assets.py

rootfs:
	./build-rootfs.sh

image: fetch rootfs
	./build-image.sh

clean:
	rm -rf out work firmware
