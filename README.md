````markdown
# [TOOL][BPI-R4][DEBIAN-TRIXIE] Banana Pi R4 Trixie Builder

Minimal image builder for Banana Pi R4 (MT7988 / Filogic 880).  
Produces a clean Debian Trixie (13) arm64 SD image with kernel 6.12 or newer.  
Single-board focus. No multi-device logic. No excess glue.

---

### FEATURES

- Debian Trixie arm64 root filesystem  
- Kernel 6.12 + Wi-Fi 7 (BPI-NIC-BE14 / MT7996)  
- Choice between fetching binaries or compiling U-Boot + kernel locally  
- Deterministic tarball and image hashes  
- Works on Ubuntu 24.04 LTS or any recent Debian-based host  
- Minimal POSIX shell + Python 3 toolchain

---

### HOST SETUP

Install the base dependencies:

```bash
sudo ./bootstrap.sh
````

For full local compilation:

```bash
sudo apt install gcc-aarch64-linux-gnu bc flex bison \
  libssl-dev libncurses5-dev
```

---

### BUILD COMMANDS

Clone and build:

```bash
git clone https://github.com/ZonG0D/bpi-r4-trixie-builder.git
cd bpi-r4-trixie-builder
make fetch   # default: use prebuilt kernel/uboot assets
             # downloads artifacts listed in assets-manifest.json
```

or build everything from source:

```bash
make local   # compile kernel + uboot locally, firmware via kernel.org
```

cleanup:

```bash
make clean
```

Artifacts are placed in `out/`:

```
bpi-r4_trixie_6.12_sdmmc.img.gz
bpi-r4_trixie_6.12_sdmmc.img.gz.sha256
trixie_arm64.tar.gz
logs/
```

---

### FLASHING IMAGE

```bash
gunzip -c out/bpi-r4_trixie_6.12_sdmmc.img.gz | \
sudo dd of=/dev/sdX bs=1M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct SD device.
All data on that drive will be destroyed.

---

### FIRST BOOT

Serial console 115200 8N1 or LAN (DHCP).
Credentials:

```
login: root
pass : zong0d
```

After login:

```
passwd
```

If Wi-Fi 7 fails to load:

```bash
ls /lib/firmware/mediatek/
lsmod | grep mt76
dmesg | grep mediatek
```

Expected firmware set:

```
mt7996_dsp.bin
mt7996_wa_233.bin
mt7996_wm_233.bin
mt7996_eeprom_233.bin
mt7996_rom_patch_233.bin
mt7988/i2p5ge-phy-pmb.bin
aeonsemi/as21x1x_fw.bin
```

---

### TREE LAYOUT

```
r4-config.sh      – Board constants and US Debian mirrors
bootstrap.sh      – Host dependency validator / installer
build-rootfs.sh   – Creates Debian Trixie arm64 root filesystem
build-kernel.sh   – Optional kernel (6.12+) build
build-uboot.sh    – Optional U-Boot build
build-image.sh    – Assembles bootable SDMMC image
fetch-assets.py   – Fetches firmware / verified binaries
assets-manifest.json – Release + firmware checksum manifest
Makefile          – Entry: make fetch | make local | make clean
conf/             – Network + service templates
firmware/         – Optional local cache
out/              – Final artifacts and checksums
```

---

### NOTES

* Enforces `/usr/bin/qemu-aarch64-static` for chroot operations
* Uses US Debian mirrors (`deb.debian.org`, `security.debian.org`)
* Fully deterministic build output
* Only critical vendor blobs included
* Compact code base for debug and CI integration

---

### LICENSE

Scripts under MIT.
Kernel / firmware retain vendor licenses.

---

**For developers building clean, reproducible R4 images.**

```
```
