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
payload_files = [
    "install.sh", "uninstall.sh", "vibeshine-drmctl",
    "vibeshine-vkms", "vibeshine-vkms-quiesce",
    "vibeshine-vkms.service", "vibeshine-vkms-control.socket",
    "vibeshine-vkms-control@.service",
]
integration_dir = root / "integration"

for ruby_file in (formula, cask):
    subprocess.run(["ruby", "-c", str(ruby_file)], check=True)
for name in ("install.sh", "uninstall.sh", "vibeshine-drmctl"):
    path = payload_dir / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Missing or unsafe Cask payload script: {path}")
    subprocess.run(["bash", "-n", str(path)], check=True)
for name in payload_files[-3:]:
    path = integration_dir / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Missing or unsafe systemd unit: {path}")

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
                if member.name in ("install.sh", "uninstall.sh", "vibeshine-drmctl"):
                    source_path = payload_dir / member.name
                elif member.name in payload_files[-3:]:
                    source_path = integration_dir / member.name
                else:
                    source_path = None
                stream = bundle.extractfile(member)
                if stream is None:
                    raise SystemExit(f"Could not read {label} member: {member.name}")
                member_bytes = stream.read()
                if source_path is not None and member_bytes != source_path.read_bytes():
                    raise SystemExit(f"{label} content differs from {source_path}")
                expected_mode = 0o644 if member.name in payload_files[-3:] else 0o755
                if stat.S_IMODE(member.mode) != expected_mode:
                    raise SystemExit(f"{label} permissions differ for {member.name}")
                if member.name in ("vibeshine-vkms", "vibeshine-vkms-quiesce"):
                    with tempfile.NamedTemporaryFile() as script:
                        script.write(member_bytes)
                        script.flush()
                        subprocess.run(["bash", "-n", script.name], check=True)
    except tarfile.TarError as error:
        raise SystemExit(f"Invalid {label} archive: {error}") from error

# Build and verify the exact local payload using the pinned source bundle.
formula_text = formula.read_text(encoding="utf-8")
source_url_match = re.search(r'^  url "([^"]+)"$', formula_text, re.MULTILINE)
if not source_url_match:
    raise SystemExit("DRM Formula source URL is missing")
source_url = source_url_match.group(1)

with tempfile.TemporaryDirectory(prefix="vibepollo-drm-check-") as temp:
    source_archive = pathlib.Path(temp) / "vibepollo-source.tar.gz"
    source_request = urllib.request.Request(
        source_url,
        headers={"User-Agent": "vibepollo-homebrew-package-check"},
    )
    try:
        with urllib.request.urlopen(source_request, timeout=120) as response:
            source_archive.write_bytes(response.read())
    except (urllib.error.URLError, TimeoutError) as error:
        raise SystemExit(f"Could not download the pinned source archive {source_url}: {error}") from error
    archive = pathlib.Path(temp) / "vibepollo-drm-integration.tar.gz"
    subprocess.run(
        ["bash", str(root / "scripts/package-cask-payload.sh"), str(archive), str(source_archive)],
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
with tarfile.open(fileobj=io.BytesIO(published_archive), mode="r:gz") as published_bundle:
    published_names = sorted(member.name for member in published_bundle.getmembers())
if published_names == sorted(payload_files):
    verify_payload_archive(published_archive, "published Cask payload")
else:
    print("Published Cask payload is stale relative to this branch; local payload was fully verified.")

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

for label, passed in checks:
    if not passed:
        raise SystemExit(f"Failed interactive sudo lifecycle check: {label}")



checks = [
    ("Cask scripts do not force graphical sudo askpass", re.search(r"^\s*sudo:\s*true\s*,?\s*$", cask_text, re.MULTILINE) is None),
    ("Cask installer elevates through terminal sudo", 'exec sudo -- "$0" "$@"' in install_text),
    ("Cask uninstaller elevates through terminal sudo", 'exec sudo -- "$0" "$@"' in uninstall_text),
    ("privileged Cask scripts escalate before requiring root", install_text.index('exec sudo -- "$0" "$@"') < install_text.index('[[ "$EUID" -eq 0 ]]') and uninstall_text.index('exec sudo -- "$0" "$@"') < uninstall_text.index('[[ "$EUID" -eq 0 ]]')),
    ("pinned source commit in formula", "b6874684d82925d0d76f487d8e4ba3ec71c9721a" in formula_text),
    ("commit-qualified module version", 'LIBVIRTUALDISPLAY_COMMIT[0, 12]' in formula_text),
    ("matching key pair validation", "KEY_FINGERPRINT" in install_text and "CERT_FINGERPRINT" in install_text),
    ("unencrypted-key validation", "-passin pass:" in install_text),
    ("pool controller loads without a default configfs device", '"create_default_dev=0"' in controller_text),
    ("pool provisioner delegates module loading to controller", 'controller" load' in (root / "scripts/apply-homebrew-patches.py").read_text(encoding="utf-8")),
    ("systemd pool units are not enabled by the package", re.search(r"^\[Install\]$", (integration_dir / "vibeshine-vkms.service").read_text(encoding="utf-8"), re.MULTILINE) is None),
    ("Cask does not start or enable services", re.search(r"^\s*systemctl\s+(?:start|enable)\b", install_text, re.MULTILINE) is None),
    ("no automatic module loading", 'insmod "$MODULE_FILE"' not in install_text),
    ("no service activation", re.search(r"^\s*systemctl\s+(?:start|enable)\b", install_text, re.MULTILINE) is None),
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
