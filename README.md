# [TOOL][BPI-R4][DEBIAN-TRIXIE] Banana Pi R4 Trixie Builder

Minimal image builder for the Banana Pi R4 (MediaTek MT7988 / Filogic 880).
Produces a clean Debian Trixie (13) arm64 SD image bundled with the latest
vendor U-Boot and a Wi-Fi 7 capable kernel.

---

### FEATURES

- Debian Trixie arm64 root filesystem generated with `debootstrap`
- Vendor U-Boot SDMMC image and mainline-derived kernel bundle fetched
automatically
- Optional local firmware cache that is injected into the final image
- Deterministic tarball and image hashing for reproducible artifacts
- Minimal Bash + Python 3 toolchain suitable for CI usage

---

### HOST REQUIREMENTS

The build scripts must be executed as `root` (or via `sudo`) because they rely
on `chroot`, `losetup`, and bind mounts.

Install the required packages on a Debian/Ubuntu host:

```bash
sudo apt update
sudo apt install \
  debootstrap qemu-user-static curl tar gzip xz-utils rsync \
  python3 dosfstools e2fsprogs parted util-linux
```

The tool only depends on the system Python 3 runtime and standard library.

---

### BUILD COMMANDS

Clone and build:

```bash
git clone https://github.com/ZonG0D/bpi-r4-trixie-builder.git
cd bpi-r4-trixie-builder
sudo make           # equivalent to: make image
```

The Makefile targets are:

```bash
make fetch   # download U-Boot, kernel bundle, and firmware blobs
make rootfs  # create the Debian Trixie root filesystem tarball
make image   # assemble the bootable SDMMC image (default target)
make clean   # remove out/, work/, and firmware/ directories
```

Artifacts are written to `out/`:

```
bpi-r4_sdmmc.img.gz           # vendor U-Boot base image
bpi-r4_*main*.tar.gz           # kernel bundle downloaded from GitHub
trixie_arm64.tar.gz            # generated rootfs tarball
bpi-r4_trixie_6.12_sdmmc.img.gz
*.sha256                       # checksums for every artifact
```

---

### FLASHING THE IMAGE

```bash
gunzip -c out/bpi-r4_trixie_6.12_sdmmc.img.gz | \
  sudo dd of=/dev/sdX bs=1M status=progress conv=fsync
```

Replace `/dev/sdX` with the correct SD card device. All data on the target
will be destroyed.

---

### FIRST BOOT

- Serial console: 115200 8N1, or LAN via DHCP
- Hostname: `bpi-r4`
- Credentials:

```
login: root
pass : bananapi
```

Change the password immediately after logging in:

```bash
passwd
```

If Wi-Fi fails to load, confirm the firmware is present and check `dmesg` for
errors:

```bash
ls /lib/firmware/mediatek/
lsmod | grep mt76
dmesg | grep -iE 'mt79|wifi'
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

### WI-FI CONFIGURATION

- The build enables `hostapd` with dedicated configurations for each radio at
  `/etc/hostapd/hostapd-2g.conf`, `/etc/hostapd/hostapd-5g.conf`, and
  `/etc/hostapd/hostapd-6g.conf`, bridging every network to its isolated WAN
  segment.
- The regulatory domain is applied at boot by `wifi-regdom.service`, which
  defaults to `US`. Override it by exporting `WIFI_REGDOMAIN=CC` when invoking
  the build scripts, or by editing `/etc/default/wifi-regdom` on the device.
- Run `/usr/local/sbin/wifi-health.sh` for a quick status report covering the
  regulatory database, active PHY capabilities, `hostapd`, and nftables.

---

### PROJECT LAYOUT

```
Makefile         – `make fetch`, `make rootfs`, `make image`, `make clean`
build-rootfs.sh  – Generates the Debian root filesystem tarball
build-image.sh   – Assembles the final SDMMC image from downloaded assets
fetch-assets.py  – Downloads vendor U-Boot, kernel bundle, and firmware
r4-config.sh     – Shared configuration and helper functions
```

---

### NOTES

- `qemu-aarch64-static` is copied into the chroot for arm64 package
  configuration
- Debian mirrors default to `deb.debian.org` and `security.debian.org`
- Output directories (`out/`, `work/`, `firmware/`) are created automatically
- The build is deterministic when the upstream artifacts remain unchanged

---

### LICENSE

Scripts are released under the MIT license. Kernel and firmware binaries retain
their original vendor licenses.

---

**For developers building clean, reproducible R4 images.**
