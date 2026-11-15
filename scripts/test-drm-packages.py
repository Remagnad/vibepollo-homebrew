#!/usr/bin/env python3
"""Static syntax, packaging, published-checksum and lifecycle checks for DRM packages."""
from __future__ import annotations

import hashlib
import io
import pathlib
import re
import stat
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.request

root = pathlib.Path(__file__).resolve().parents[1]
formula = root / "Formula/vibepollo-drm.rb"
cask = root / "Casks/vibepollo.rb"
payload_dir = root / "cask-payload"
payload_files = ["install.sh", "uninstall.sh", "vibeshine-drmctl"]

for ruby_file in (formula, cask):
    subprocess.run(["ruby", "-c", str(ruby_file)], check=True)
for name in payload_files:
    path = payload_dir / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Missing or unsafe Cask payload script: {path}")
    subprocess.run(["bash", "-n", str(path)], check=True)

cask_text = cask.read_text(encoding="utf-8")
version_match = re.search(r'^  version "([^"]+)"$', cask_text, re.MULTILINE)
sha_match = re.search(r'^  sha256 "([0-9a-f]{64})"$', cask_text, re.MULTILINE)
url_match = re.search(r'^  url "([^"]+)"$', cask_text, re.MULTILINE)
if not version_match or not sha_match or not url_match:
    raise SystemExit("Cask must define one version, URL and 64-character payload SHA-256")

version = version_match.group(1)
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit(f"Invalid stable Cask version: {version!r}")
expected_url_template = (
    'https://github.com/Remagnad/vibepollo-homebrew/releases/download/'
    'vibepollo-#{version}/vibepollo-drm-integration-#{version}.tar.gz'
)
if url_match.group(1) != expected_url_template:
    raise SystemExit("Cask URL must remain version-interpolated and point at the release payload")
published_url = url_match.group(1).replace("#{version}", version)

def verify_payload_archive(archive_bytes: bytes, label: str) -> None:
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as bundle:
            members = bundle.getmembers()
            names = [member.name for member in members]
            if sorted(names) != sorted(payload_files):
                raise SystemExit(f"Unexpected {label} members: {names}")
            for member in members:
                if not member.isfile():
                    raise SystemExit(f"Unsafe non-regular file in {label}: {member.name}")
                source_path = payload_dir / member.name
                stream = bundle.extractfile(member)
                if stream is None or stream.read() != source_path.read_bytes():
                    raise SystemExit(f"{label} content differs from {source_path}")
                expected_mode = stat.S_IMODE(source_path.stat().st_mode)
                if stat.S_IMODE(member.mode) != expected_mode:
                    raise SystemExit(f"{label} permissions differ for {member.name}")
    except tarfile.TarError as error:
        raise SystemExit(f"Invalid {label} archive: {error}") from error

# Validate the package script independently. Its archive timestamp may differ
# from the published release timestamp, so its compressed SHA is not expected
# to equal the Cask's SHA-256.
with tempfile.TemporaryDirectory(prefix="vibepollo-drm-check-") as temp:
    archive = pathlib.Path(temp) / "vibepollo-drm-integration.tar.gz"
    subprocess.run(
        ["bash", str(root / "scripts/package-cask-payload.sh"), str(archive)],
        check=True,
    )
    local_archive = archive.read_bytes()
    verify_payload_archive(local_archive, "locally packaged Cask payload")
    archive_sha = hashlib.sha256(local_archive).hexdigest()

# Verify the exact release asset that Homebrew will download. The package
# workflow sets SOURCE_DATE_EPOCH from the upstream release timestamp; building
# the archive here with a different timestamp would produce a different SHA
# despite identical file contents.
request = urllib.request.Request(
    published_url,
    headers={"User-Agent": "vibepollo-homebrew-package-check"},
)
try:
    with urllib.request.urlopen(request, timeout=60) as response:
        published_archive = response.read()
except (urllib.error.URLError, TimeoutError) as error:
    raise SystemExit(f"Could not download the published Cask payload {published_url}: {error}") from error

published_sha = hashlib.sha256(published_archive).hexdigest()
if published_sha != sha_match.group(1):
    raise SystemExit(
        f"Published Cask checksum mismatch: Cask={sha_match.group(1)}, "
        f"release asset={published_sha}"
    )
verify_payload_archive(published_archive, "published Cask payload")

subprocess.run(
    [
        "python3", str(root / "scripts/render-drm-packages.py"),
        "--version", "9.8.7",
        "--source-url", "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-9.8.7/vibepollo-source-9.8.7.tar.gz",
        "--source-sha", "a" * 64,
        "--libvirtualdisplay-commit", "b" * 40,
        "--cask-url", "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-9.8.7/vibepollo-drm-integration-9.8.7.tar.gz",
        "--cask-sha", archive_sha,
        "--formula-template", str(formula),
        "--cask-template", str(cask),
        "--formula-output", str(pathlib.Path(temp) / "Formula/vibepollo-drm.rb"),
        "--cask-output", str(pathlib.Path(temp) / "Casks/vibepollo.rb"),
    ],
    check=True,
)
rendered_formula = (pathlib.Path(temp) / "Formula/vibepollo-drm.rb").read_text()
rendered_cask = (pathlib.Path(temp) / "Casks/vibepollo.rb").read_text()
if "vibepollo-source-9.8.7.tar.gz" not in rendered_formula or ("b" * 40) not in rendered_formula:
    raise SystemExit("DRM Formula source URL or libvirtualdisplay commit was not rendered")
if 'version "9.8.7"' not in rendered_cask or archive_sha not in rendered_cask:
    raise SystemExit("DRM Cask release metadata was not rendered")
if '#{version}/vibepollo-drm-integration-#{version}.tar.gz' not in rendered_cask:
    raise SystemExit("DRM Cask URL must use Homebrew version interpolation")

formula_text = formula.read_text(encoding="utf-8")
install_text = (payload_dir / "install.sh").read_text(encoding="utf-8")
uninstall_text = (payload_dir / "uninstall.sh").read_text(encoding="utf-8")
controller_text = (payload_dir / "vibeshine-drmctl").read_text(encoding="utf-8")

checks = [
    ("pinned source commit in formula", "b6874684d82925d0d76f487d8e4ba3ec71c9721a" in formula_text),
    ("commit-qualified module version", 'LIBVIRTUALDISPLAY_COMMIT[0, 12]' in formula_text),
    ("matching key pair validation", "KEY_FINGERPRINT" in install_text and "CERT_FINGERPRINT" in install_text),
    ("unencrypted-key validation", "-passin pass:" in install_text),
    ("no automatic module loading", 'insmod "$MODULE_FILE"' not in install_text),
    ("no service activation", "systemctl enable" not in install_text and "systemctl start" not in install_text),
    ("no Secure Boot enrollment", "mokutil --import" not in install_text and "AUTO_ENROLL" not in install_text),
    ("controller ownership marker", "write_managed_load 1" in controller_text),
    ("module token parameter injected before Kbuild", "module_param_string(vibeshine_drmctl_token" in formula_text),
    ("existing Kbuild source is edited with Homebrew inreplace", "inreplace driver_source do |s|" in formula_text and "driver_source.write(" not in formula_text),
    ("controller generates a unique 256-bit token", "od -An -N32 -tx1 /dev/urandom" in controller_text),
    ("controller passes token to insmod", '"vibeshine_drmctl_token=$LOAD_TOKEN"' in controller_text),
    ("controller validates the live token before unload", "check_managed_load_token" in controller_text),
    ("uninstaller validates the live token", "expected_token" in uninstall_text and "loaded_token" in uninstall_text),
    ("safe uninstaller ownership check", '"$(state_value managed_load)" == "1"' in uninstall_text),
    ("key preservation", "Preserved signing keys" in uninstall_text),
    ("no incorrect sig_key/serial comparison", "modinfo -F sig_key" not in install_text + controller_text),
]
for label, passed in checks:
    if not passed:
        raise SystemExit(f"Failed DRM lifecycle check: {label}")

print("Vibeshine DRM Formula/Cask syntax, payloads, published checksum, renderer and lifecycle checks passed.")
