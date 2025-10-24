#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.error
import urllib.request

OUT_DIR = Path.cwd() / "out"
FIRMWARE_DIR = Path.cwd() / "firmware"
GITHUB_HEADERS = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "bpi-r4-trixie-builder"
}

UBOOT_REPO = "frank-w/u-boot"
KERNEL_REPO = "frank-w/BPI-Router-Linux"
KERNEL_VERSION_PATTERN = re.compile(r"6\.12\.")

FIRMWARE_SOURCES = {
    "mediatek/mt7996/mt7996_dsp.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7996/mt7996_dsp.bin",
    "mediatek/mt7996/mt7996_eeprom_233.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7996/mt7996_eeprom_233.bin",
    "mediatek/mt7996/mt7996_rom_patch_233.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7996/mt7996_rom_patch_233.bin",
    "mediatek/mt7996/mt7996_wa_233.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7996/mt7996_wa_233.bin",
    "mediatek/mt7996/mt7996_wm_233.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7996/mt7996_wm_233.bin",
    "mediatek/mt7988/i2p5ge-phy-pmb.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7988/i2p5ge-phy-pmb.bin",
    "aeonsemi/as21x1x_fw.bin": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/aeonsemi/as21x1x_fw.bin",
}


def github_request(url: str):
    req = urllib.request.Request(url, headers=GITHUB_HEADERS)
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def find_uboot_asset():
    releases = github_request(f"https://api.github.com/repos/{UBOOT_REPO}/releases")
    for release in releases:
        for asset in release.get("assets", []):
            if asset.get("name") == "bpi-r4_sdmmc.img.gz":
                return asset["browser_download_url"], asset["name"]
    raise SystemExit("Unable to locate bpi-r4_sdmmc.img.gz in U-Boot releases")


def find_kernel_asset():
    releases = github_request(f"https://api.github.com/repos/{KERNEL_REPO}/releases")
    for release in releases:
        tag = release.get("tag_name", "")
        if "main" not in tag:
            continue
        for asset in release.get("assets", []):
            name = asset.get("name", "")
            if not name.startswith("bpi-r4_"):
                continue
            if not name.endswith(".tar.gz"):
                continue
            if not KERNEL_VERSION_PATTERN.search(name):
                continue
            return asset["browser_download_url"], asset["name"]
    raise SystemExit("Unable to locate 6.12 main kernel bundle for bpi-r4")


def sha256sum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path):
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        with urllib.request.urlopen(url) as response, tempfile.NamedTemporaryFile(delete=False) as tmp:
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                tmp.write(block)
            tmp_path = Path(tmp.name)
    except urllib.error.URLError as exc:
        raise SystemExit(f"Failed to download {url}: {exc}")

    tmp_path.chmod(0o644)
    os.replace(tmp_path, destination)

    checksum = sha256sum(destination)
    with destination.with_suffix(destination.suffix + ".sha256").open("w", encoding="utf-8") as handle:
        handle.write(f"{checksum}  {destination.name}\n")
    print(f"[OK] Downloaded {destination.name}")


FIRMWARE_HEADERS = {
    "User-Agent": "bpi-r4-trixie-builder",
}


def download_firmware():
    for relative, url in FIRMWARE_SOURCES.items():
        dest = FIRMWARE_DIR / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(url, headers=FIRMWARE_HEADERS)
        try:
            with urllib.request.urlopen(request) as response, tempfile.NamedTemporaryFile(delete=False) as tmp:
                while True:
                    block = response.read(1024 * 1024)
                    if not block:
                        break
                    tmp.write(block)
                tmp_path = Path(tmp.name)
        except urllib.error.URLError as exc:
            raise SystemExit(f"Failed to download firmware from {url}: {exc}")
        tmp_path.chmod(0o644)
        os.replace(tmp_path, dest)
        print(f"[OK] Firmware {relative}")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    FIRMWARE_DIR.mkdir(parents=True, exist_ok=True)

    uboot_url, uboot_name = find_uboot_asset()
    download(uboot_url, OUT_DIR / uboot_name)

    kernel_url, kernel_name = find_kernel_asset()
    download(kernel_url, OUT_DIR / kernel_name)

    download_firmware()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(1)
