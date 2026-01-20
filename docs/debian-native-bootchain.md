# Debian-Native Bootloader + Toolchain Workflow for BPI-R4

This guide defines a Debian-native bootloader and compiler/toolchain workflow
for the Banana Pi BPI-R4 (MediaTek MT7988A / Filogic 880).

## Scope and Goal

The objective is to:

- Build and control the entire boot chain suitable for Debian 13.
- Produce a reproducible cross-compilation environment.
- Boot a mainline-oriented Linux kernel with a Debian root filesystem.
- Avoid OpenWrt assumptions, tooling, layouts, or abstractions.

## Target Platform Summary (Relevant to Debian)

- **SoC:** MediaTek MT7988A (Arm Cortex-A73, quad-core)
- **Architecture:** AArch64 (ARMv8)
- **Boot Media:**
  - Primary: microSD
  - Secondary: eMMC
  - Advanced: SPI NAND
- **Firmware Model:** Non-UEFI, multi-stage vendor boot flow
- **Typical Stack:**
  - BootROM → BL2 / Preloader → TF-A (BL31) → U-Boot → Linux kernel → Debian userspace

## Host Development Environment

### Supported Host OS

- Ubuntu 22.04 LTS (primary reference)
- Ubuntu 20.04 or 24.04 expected to work with minor adjustments

### Required Host Packages

Minimum build dependencies:

- build-essential
- gcc-aarch64-linux-gnu
- binutils-aarch64-linux-gnu
- device-tree-compiler
- bc
- bison
- flex
- libssl-dev
- libncurses-dev
- python3
- python3-pip
- git
- wget
- curl

## Toolchain Strategy (Debian-Centric)

### Default Toolchain (Recommended)

Use the Debian / GNU cross toolchain:

- Compiler: aarch64-linux-gnu-gcc
- libc: glibc (Debian default)
- Binutils: Debian-provided

This aligns with:

- Debian kernel builds
- Debian rootfs ABI expectations
- Long-term maintenance

### Optional: Custom GCC Toolchain

Only required if:

- Patching GCC/binutils
- Strict reproducibility mandates
- Non-default ABI or LTO experiments

Otherwise, the prebuilt Debian toolchain is preferred.

## Bootloader Stack (Debian-Oriented)

### Components

The Debian boot chain for BPI-R4 consists of:

- **BL2 / Preloader**
  - MediaTek-specific
  - Handles DRAM init and early SoC setup
- **Arm Trusted Firmware (TF-A)**
  - EL3 firmware
  - Secure monitor and PSCI
- **U-Boot**
  - Primary bootloader
  - Loads kernel, initrd, DTB

### Build Principles

- Build each stage independently.
- Use mainline sources when possible.
- Vendor forks only where hardware support requires it.
- Keep artifacts clearly separated:

```
out/
  bl2/
  tf-a/
  u-boot/
  kernel/
```

## Linux Kernel for Debian 13

### Kernel Source Options

- Preferred: Mainline Linux
- Acceptable: Vendor BSP kernel only if required for hardware enablement

Target kernel features:

- CONFIG_ARM64
- CONFIG_PCI
- CONFIG_MTD, CONFIG_MMC
- CONFIG_NET_DSA_MEDIATEK
- CONFIG_SFP
- Debian-compatible config baseline

### Device Tree

Board-specific DTS is required for:

- MT7988A
- Ethernet switch
- SFP ports
- PCIe
- Storage controllers

DTB must be:

- Passed by U-Boot
- Matched to kernel version

## Debian 13 (Trixie) Root Filesystem

### Rootfs Creation

Recommended approach:

```
debootstrap --arch=arm64 trixie rootfs/
```

Configure:

- systemd
- openssh-server, net-tools, iproute2
- Serial console enabled

### Init and Console

- Serial console: ttyS0 or SoC UART (115200 8N1)
- Kernel cmdline example:

```
console=ttyS0,115200 root=/dev/mmcblk0p2 rw
```

## Boot Medium Strategy

### Phase 1: SD Card (Recommended)

Reasons:

- Safe recovery
- Easy iteration
- Matches board jumper defaults

Layout example:

```
SD:
  p1  FAT32   → U-Boot env / kernel / DTB
  p2  ext4    → Debian rootfs
```

### Phase 2: eMMC

After SD boot stability:

- Flash bootloader stages to eMMC boot partitions
- Copy kernel + rootfs
- Switch boot jumpers

### Phase 3: SPI NAND (Advanced)

Only after:

- Boot chain validated
- Partition layout finalized
- UBI/MTD fully understood

## Debug and Bring-Up

### Serial Console

- USB-Serial: 3.3V TTL
- Baud: 115200

Required for:

- Bootloader logs
- Early kernel debugging
- Recovery

### Common Failure States

- System halt! → no valid OS in selected boot medium
- Silent boot → incorrect boot stage or DRAM init failure
- Kernel panic early → DTB mismatch or missing drivers

## Outcome

Following this guide results in:

- A Debian 13 native boot chain
- Full control over:
  - Bootloader
  - Kernel
  - Toolchain
- No OpenWrt dependency
- Clean separation between firmware, kernel, and userspace
- A platform suitable for:
  - Networking
  - Storage
  - Debian-based services
  - Long-term maintenance

## Repository Workflow Mapping

This repository follows the workflow by providing:

- `conf/bootchain.env` to pin bootchain sources and build commands.
- `build-bootchain.sh` to build BL2, TF-A, and U-Boot independently.
- `build-kernel.sh` to build and bundle the kernel + modules.
- `out/` subdirectories (`bl2/`, `tf-a/`, `u-boot/`, `kernel/`) to keep artifacts
  separated by stage.
