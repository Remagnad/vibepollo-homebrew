#!/usr/bin/env python3
"""Static syntax, packaging, published-checksum and lifecycle checks for DRM packages."""
from __future__ import annotations

import hashlib
import os
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
migration_helper = root / "scripts/migrate-installed-cask-sudo.py"
if not migration_helper.is_file() or migration_helper.is_symlink():
    raise SystemExit(f"Missing or unsafe installed-Cask migration helper: {migration_helper}")
subprocess.run(["python3", str(migration_helper), "--self-test"], check=True)

for name in ("install.sh", "uninstall.sh", "vibeshine-drmctl"):
    path = payload_dir / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Missing or unsafe Cask payload script: {path}")
    subprocess.run(["bash", "-n", str(path)], check=True)
for name in payload_files[-3:]:
    path = integration_dir / name
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"Missing or unsafe systemd unit: {path}")

# Regression test: some systemd builds report an inactive unit as exit 4
# while still printing the unambiguous state "inactive".
unit_match = re.search(
    r"(?ms)^unit_is_active\(\) \{\n.*?^\}",
    (payload_dir / "uninstall.sh").read_text(encoding="utf-8"),
)
if not unit_match or "4:inactive" not in unit_match.group(0):
    raise SystemExit("Uninstaller must treat systemctl exit 4 + inactive as an inactive unit")
with tempfile.TemporaryDirectory(prefix="vibepollo-systemctl-test-") as temp:
    mock_bin = pathlib.Path(temp) / "bin"
    mock_bin.mkdir()
    mock_systemctl = mock_bin / "systemctl"
    mock_systemctl.write_text("#!/bin/sh\nprintf 'inactive\\n'\nexit 4\n")
    mock_systemctl.chmod(0o755)
    harness = (
        'fail() { echo "unexpected failure: $*" >&2; exit 99; }\n'
        + unit_match.group(0)
        + '\nif unit_is_active vibeshine-vkms.service; then '
          'echo "inactive unit reported active" >&2; exit 1; '
          'else rc=$?; test "$rc" -eq 1; fi\n'
    )
    env = os.environ.copy()
    env["PATH"] = f"{mock_bin}:{env.get('PATH', '/usr/bin:/bin')}"
    subprocess.run(["bash", "-c", harness], env=env, check=True)
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

def verify_payload_archive(archive_bytes: bytes, label: str) -> bool:
    source_matches = True
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
                expected_mode = 0o644 if member.name in payload_files[-3:] else 0o755
                if stat.S_IMODE(member.mode) != expected_mode:
                    raise SystemExit(f"{label} permissions differ for {member.name}")
                if member.name in ("vibeshine-vkms", "vibeshine-vkms-quiesce"):
                    with tempfile.NamedTemporaryFile() as script:
                        script.write(member_bytes)
                        script.flush()
                        subprocess.run(["bash", "-n", script.name], check=True)
                if source_path is not None and member_bytes != source_path.read_bytes():
                    source_matches = False
    except tarfile.TarError as error:
        raise SystemExit(f"Invalid {label} archive: {error}") from error
    return source_matches

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
    if not verify_payload_archive(local_archive, "locally packaged Cask payload"):
        raise SystemExit("Local Cask payload differs from its source files")
    archive_sha = hashlib.sha256(local_archive).hexdigest()

# The standalone Cask workflow validates the new local payload before publishing it.
# In that transaction the previous release asset is expected to be stale, so
# skip only the remote-asset comparison when explicitly requested.
if os.environ.get("VIBEPOLLO_SKIP_PUBLISHED_ASSET_CHECK") == "1":
    print("Skipping published-asset comparison for the pre-publication Cask workflow.")
else:
    # Verify the exact release asset that Homebrew will download. The Cask
    # workflow sets SOURCE_DATE_EPOCH from the upstream release timestamp;
    # building with a different timestamp changes the archive SHA-256.
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
        published_matches = verify_payload_archive(published_archive, "published Cask payload")
        if not published_matches:
            print("Published Cask payload is stale relative to this branch; its checked-in SHA-256 is valid and the local payload was fully verified.")
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

checks = [
    ("Cask removes inherited graphical askpass only for interactive uninstall", 'if STDIN.tty? && ENV.key?("SUDO_ASKPASS")' in cask_text and 'ENV.delete("SUDO_ASKPASS")' in cask_text),
    ("Cask restores askpass after uninstall and on process exit", 'ENV["SUDO_ASKPASS"] = saved_sudo_askpass' in cask_text and "at_exit do" in cask_text and "uninstall_postflight do" in cask_text),
    ("Cask keeps Homebrew sudo enabled", re.search(r"(?s)uninstall script: \{.*?sudo:\s*true", cask_text) is not None),
    ("Cask delegates uninstall privilege escalation to Homebrew", re.search(r"(?s)uninstall script: \{.*?sudo:\s*true", cask_text) is not None),
    ("Cask installer elevates through sudo", 'exec sudo -- "$0" "$@"' in install_text),
    ("Cask uninstaller requires Homebrew root execution", '[[ "$EUID" -eq 0 ]] || fail "Homebrew must run this uninstaller with sudo: true"' in uninstall_text),
    ("Cask uninstaller does not invoke sudo itself", "sudo -v" not in uninstall_text and "SUDO_ASKPASS" not in uninstall_text and "sudo -n" not in uninstall_text),
    ("Cask uninstaller bounds systemd and rmmod operations", 'systemctl_bounded 45' in uninstall_text and 'timeout --foreground --kill-after=5s 10s rmmod' in uninstall_text),
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
    ("safe uninstaller ownership check", 'elif [[ "$(state_value managed_load)" != "1" ]]' in uninstall_text and "MODULE_UNVERIFIED_LOADED=1" in uninstall_text and 'if [[ "$STATE_TRUSTED" != "1" || "$MODULE_UNVERIFIED_LOADED" == "1" ]]' in uninstall_text),
    ("key preservation", "Preserved signing keys" in uninstall_text),
    ("no incorrect sig_key/serial comparison", "modinfo -F sig_key" not in install_text + controller_text),
]
for label, passed in checks:
    if not passed:
        raise SystemExit(f"Failed DRM lifecycle check: {label}")

print("Vibeshine DRM Formula/Cask syntax, payloads, published checksum, renderer and lifecycle checks passed.")
