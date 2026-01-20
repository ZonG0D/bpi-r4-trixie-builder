# [TOOL][BPI-R4][DEBIAN-TRIXIE] Banana Pi R4 Trixie Builder

Minimal image builder for the Banana Pi R4 (MediaTek MT7988 / Filogic 880).
Produces a clean Debian Trixie (13) arm64 SD image with a Debian-native
bootchain workflow and a Wi-Fi 7 capable kernel.

---

### FEATURES

- Debian Trixie arm64 root filesystem generated with `debootstrap`
- Debian-native bootchain workflow for BL2/TF-A/U-Boot plus a kernel bundle
build that stages artifacts under `out/`
- Optional local firmware cache that is injected into the final image
- Deterministic tarball and image hashing for reproducible artifacts
- Minimal Bash + Python 3 toolchain suitable for CI usage

---

### HOST REQUIREMENTS

The build scripts must be executed as `root` (or via `sudo`) because they rely
on `chroot`, `losetup`, and bind mounts.

Run the host preparation script to install and validate the required tooling
before building:

```bash
sudo ./prepare-host.sh
```

The helper installs `debootstrap`, `qemu-user-static`, `binfmt-support`, the
Debian archive keyring, filesystem utilities (`dosfstools`, `e2fsprogs`),
partitioning tools (`parted`, `kpartx`), file synchronization (`rsync`), and
supporting utilities. It also enables the aarch64 binfmt entry and verifies
that `qemu-aarch64-static` can execute on the host.
The build still requires the system Python 3 runtime and standard library.

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
make fetch   # download firmware blobs (set FETCH_BOOTCHAIN_ASSETS=1 for vendor bundles)
make bootchain # build BL2/TF-A/U-Boot from source using conf/bootchain.env
make kernel  # build the Linux kernel bundle for the SD image
make rootfs  # create the Debian Trixie root filesystem tarball
make image   # assemble the bootable SDMMC image (default target)
make clean   # remove out/, work/, and firmware/ directories
```

Artifacts are written to `out/`:

```
bl2/                           # BL2 / preloader artifacts
tf-a/                          # TF-A BL31 artifacts
u-boot/                        # U-Boot artifacts (expected SDMMC image)
kernel/                        # kernel bundle tarball
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
build-image.sh   – Assembles the final SDMMC image from bootchain + rootfs
build-bootchain.sh – Builds BL2, TF-A, and U-Boot from source
build-kernel.sh  – Builds and bundles the Linux kernel + modules
fetch-assets.py  – Downloads firmware (and optional vendor bootchain bundles)
r4-config.sh     – Shared configuration and helper functions
prepare-host.sh  – Installs host prerequisites and enables qemu binfmt support
```

---

### NOTES

- `qemu-aarch64-static` is copied into the chroot for arm64 package
  configuration
- Debian mirrors default to `deb.debian.org` and `security.debian.org`
- Output directories (`out/`, `work/`, `firmware/`) are created automatically
- The build is deterministic when the upstream artifacts remain unchanged

---

### BOOTCHAIN CONFIGURATION

`build-bootchain.sh` and `build-kernel.sh` source `conf/bootchain.env`. Adjust
the repository URLs, refs, and build commands there to match your desired
upstream or vendor trees. The defaults target mainline-oriented sources and can
be overridden with environment variables. For a vendor bundle fallback, set
`FETCH_BOOTCHAIN_ASSETS=1` before running `make fetch`.

---

### DOCUMENTATION

- [Debian-native bootloader + toolchain workflow](docs/debian-native-bootchain.md)

---

### LICENSE

Scripts are released under the MIT license. Kernel and firmware binaries retain
their original vendor licenses.

---

**For developers building clean, reproducible R4 images.**
