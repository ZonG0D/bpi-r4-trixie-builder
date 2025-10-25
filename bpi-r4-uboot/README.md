# Banana Pi R4 U-Boot Overlay

Minimal overlay that applies the board enablement and boot fixes required for
reliable Banana Pi R4 booting when building U-Boot from upstream sources.

## Layout

```
bpi-r4-uboot/
├── README.md
├── build.sh
├── clean.sh
├── external.mk
├── patches/
│   └── 0001-bpi-r4-board-and-config.patch
├── scripts/
│   └── make_fit.sh
├── its/
│   └── bpi-r4.its
└── toolchain.mk
```

## Usage

```
git clone https://source.denx.de/u-boot/u-boot.git u-boot-src
cd bpi-r4-uboot
./build.sh ../u-boot-src v2025.10
```

`build.sh` resets the upstream tree to the requested tag (defaults to
`v2025.10`), applies the overlay patch, builds the target, and copies the
artifacts into `out/`.

Resulting artifacts in `out/`:

- `u-boot.bin`
- `u-boot-with-spl.bin` (if provided by the SoC port)
- `bpi-r4.itb` (dummy kernel FIT for SD boot layout sanity)

The build assumes an aarch64 cross-compiler provided via `CROSS_COMPILE`. By
default it uses `aarch64-linux-gnu-`; adjust `toolchain.mk` if a different
prefix is required.

## Cleaning

To revert the source tree and remove build outputs:

```
./clean.sh ../u-boot-src
```

The clean script aborts any in-flight patch application, hard resets the U-Boot
checkout, and removes the local `out/` directory.

## Notes

- The overlay intentionally avoids bundling a Debian userspace. The resulting
  artifacts focus solely on the U-Boot boot flow fixes identified in the
  adversarial analysis.
- `scripts/make_fit.sh` emits a placeholder FIT image using empty kernel and FDT
  blobs so the generated image layout can be validated without requiring a full
  kernel build.
