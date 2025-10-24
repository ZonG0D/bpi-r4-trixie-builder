#!/usr/bin/env python3
import hashlib
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests

PROJECT_ROOT = Path(__file__).resolve().parent
LOG_DIR = PROJECT_ROOT / "out" / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = LOG_DIR / "fetch-assets.log"

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE, mode="a"),
        logging.StreamHandler(sys.stdout),
    ],
)

MANIFEST_PATH = PROJECT_ROOT / "assets-manifest.json"

if not MANIFEST_PATH.exists():
    logging.error("Missing assets manifest: %s", MANIFEST_PATH)
    sys.exit(1)

with MANIFEST_PATH.open("r", encoding="utf-8") as fh:
    manifest = json.load(fh)

ARTIFACTS = manifest.get("artifacts", [])
if not ARTIFACTS:
    logging.error("No artifacts defined in manifest")
    sys.exit(1)

filters = set(arg.lower() for arg in sys.argv[1:])
processed = 0

SESSION = requests.Session()
SESSION.headers.update({
    "User-Agent": "bpi-r4-trixie-builder/1.0",
})

def sha256sum(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def download_to(url: str, dest: Path) -> None:
    ensure_parent(dest)
    logging.info("Downloading %s", url)
    with SESSION.get(url, stream=True, timeout=120) as resp:
        if resp.status_code != 200:
            raise RuntimeError(f"Failed to download {url}: HTTP {resp.status_code}")
        tmp_path = dest.with_suffix(dest.suffix + ".tmp")
        with tmp_path.open("wb") as fh:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    fh.write(chunk)
        tmp_path.replace(dest)


def download_with_candidates(
    urls: List[str], dest: Path, expected_hash: Optional[str] = None
) -> bool:
    for url in urls:
        try:
            download_to(url, dest)
        except RuntimeError as exc:
            logging.warning("Failed to download %s: %s", url, exc)
            continue
        if expected_hash and sha256sum(dest) != expected_hash:
            logging.warning(
                "Discarding firmware from %s due to SHA256 mismatch", url
            )
            dest.unlink(missing_ok=True)
            continue
        return True
    return False


def copy_firmware_from_host(
    glob_patterns: List[str], dest: Path, expected_hash: Optional[str] = None
) -> bool:
    for base in (Path("/lib/firmware"), Path("/usr/lib/firmware")):
        for pattern in glob_patterns:
            for candidate in base.glob(pattern):
                if not candidate.is_file():
                    continue
                if expected_hash and sha256sum(candidate) != expected_hash:
                    logging.warning(
                        "Host firmware %s hash mismatch, continuing fallback", candidate
                    )
                    continue
                logging.info("Using firmware from host: %s", candidate)
                ensure_parent(dest)
                shutil.copy2(candidate, dest)
                return True

    tmp_root = Path(tempfile.mkdtemp(prefix="linux-firmware-"))
    try:
        try:
            subprocess.run(
                ["apt-get", "update"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            subprocess.run(
                ["apt-get", "download", "linux-firmware"],
                check=True,
                cwd=tmp_root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except (FileNotFoundError, subprocess.CalledProcessError) as exc:
            logging.warning("Failed to download linux-firmware package: %s", exc)
            return False

        debs = list(tmp_root.glob("linux-firmware_*.deb"))
        if not debs:
            logging.warning("No linux-firmware package found in %s", tmp_root)
            return False

        extract_dir = tmp_root / "extract"
        extract_dir.mkdir(parents=True, exist_ok=True)
        try:
            subprocess.run(
                ["dpkg-deb", "-x", str(debs[0]), str(extract_dir)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except (FileNotFoundError, subprocess.CalledProcessError) as exc:
            logging.warning("Failed to extract linux-firmware package: %s", exc)
            return False

        for base in (
            extract_dir / "lib" / "firmware",
            extract_dir / "usr" / "lib" / "firmware",
        ):
            if not base.exists():
                continue
            for pattern in glob_patterns:
                for candidate in base.glob(pattern):
                    if not candidate.is_file():
                        continue
                    if expected_hash and sha256sum(candidate) != expected_hash:
                        logging.warning(
                            "Package firmware %s hash mismatch, continuing fallback",
                            candidate,
                        )
                        continue
                    logging.info(
                        "Using firmware from downloaded package: %s", candidate
                    )
                    ensure_parent(dest)
                    shutil.copy2(candidate, dest)
                    return True
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)

    return False


def github_asset(artifact: Dict[str, Any]) -> None:
    token = os.environ.get("GITHUB_TOKEN")
    headers = {
        "Accept": "application/vnd.github+json",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    repo = artifact["repo"]
    tag = artifact["tag"]
    asset_name = artifact["asset"]
    api_url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    logging.info("Querying GitHub release %s@%s", repo, tag)
    resp = SESSION.get(api_url, headers=headers, timeout=60)
    if resp.status_code != 200:
        raise RuntimeError(f"GitHub API error {resp.status_code}: {api_url}")
    assets = resp.json().get("assets", [])
    for asset in assets:
        if asset.get("name") == asset_name:
            download_to(asset["browser_download_url"], PROJECT_ROOT / artifact["destination"])
            return
    raise RuntimeError(f"Asset {asset_name} not found in release {repo}@{tag}")


def kernel_firmware(artifact: Dict[str, Any]) -> None:
    dest = PROJECT_ROOT / artifact["destination"]
    name = artifact.get("name", "")
    expected = artifact.get("sha256")
    url = artifact["url"]

    if name == "mt7996_dsp":
        base = (
            "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"
        )
        candidates = [
            f"{base}/mediatek/mt7996/mt7996_dsp.bin",
            f"{base}/mediatek/mt7996_dsp.bin",
        ]
        if download_with_candidates(candidates, dest, expected):
            return
        patterns = [
            "mediatek/mt7996/mt7996_dsp.bin",
            "mediatek/mt7996_dsp.bin",
        ]
        if copy_firmware_from_host(patterns, dest, expected):
            return
        raise RuntimeError(
            "Could not fetch mt7996_dsp.bin via upstream or host/package fallback"
        )

    if "/mediatek/mt7996/" not in url:
        base, filename = url.rsplit("/", 1)
        if filename.startswith("mt7996_") and base.endswith("/mediatek"):
            candidates = [
                f"{base}/mt7996/{filename}",
                url,
            ]
            if download_with_candidates(candidates, dest, expected):
                return

    try:
        download_to(url, dest)
    except RuntimeError as exc:
        if "HTTP 403" in str(exc) and "?" not in url:
            logging.warning("Retrying firmware download with ?h=HEAD: %s", url)
            download_to(url + "?h=HEAD", dest)
        else:
            raise


def verify(path: Path, expected: str) -> None:
    digest = sha256sum(path)
    if digest != expected:
        raise RuntimeError(f"SHA256 mismatch for {path.name}: {digest} != {expected}")
    logging.info("Verified %s", path.name)
    with path.with_suffix(path.suffix + ".sha256").open("w", encoding="utf-8") as fh:
        fh.write(f"{digest}  {path.name}\n")


for artifact in ARTIFACTS:
    name = artifact.get("name", "unknown")
    if filters and name.lower() not in filters and artifact.get("type", "").lower() not in filters:
        continue
    logging.info("Processing artifact: %s", name)
    if artifact["type"] == "github":
        github_asset(artifact)
    elif artifact["type"] == "kernel_firmware":
        kernel_firmware(artifact)
    else:
        logging.error("Unsupported artifact type: %s", artifact["type"])
        sys.exit(1)

    dest = PROJECT_ROOT / artifact["destination"]
    if not dest.exists():
        logging.error("Download failed for %s", name)
        sys.exit(1)
    verify(dest, artifact["sha256"])
    processed += 1

if filters and processed == 0:
    logging.warning("No artifacts matched filters: %s", ", ".join(sorted(filters)))

logging.info("All assets fetched successfully")
