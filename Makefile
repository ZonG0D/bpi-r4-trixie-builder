SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: all fetch rootfs bootchain kernel image clean

all: image

fetch:
	./fetch-assets.py

rootfs:
	./build-rootfs.sh

bootchain:
	./build-bootchain.sh

kernel:
	./build-kernel.sh

image: bootchain kernel rootfs
	./build-image.sh

clean:
	rm -rf out work firmware
