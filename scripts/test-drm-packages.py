#!/usr/bin/env python3
"""Static syntax, packaging and safety checks for the DRM Formula and Cask."""

from __future__ import annotations
import pathlib, re, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parents[1]
formula = root / "Formula/vibepollo-drm.rb"
cask = root / "Casks/vibepollo.rb"
for ruby_file in (formula, cask):
    subprocess.run(["ruby", "-c", str(ruby_file)], check=True)

payload_dir = root / "cask-payload"
payload_files = ["install.sh", "uninstall.sh", "vibeshine-drmctl"]
with tempfile.TemporaryDirectory(prefix="vibepollo-drm-check-") as temp:
    for name in payload_files:
        path = payload_dir / name
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"Missing or unsafe Cask payload script: {path}")
        subprocess.run(["bash", "-n", str(path)], check=True)
    archive = pathlib.Path(temp) / "vibepollo-drm-integration.tar.gz"
    subprocess.run(["bash", str(root / "scripts/package-cask-payload.sh"), str(archive)], check=True)
    listing = subprocess.run(["tar", "-tzf", str(archive)], check=True, capture_output=True, text=True).stdout.splitlines()
    if sorted(listing) != sorted(payload_files):
        raise SystemExit(f"Unexpected Cask payload members: {listing}")
    subprocess.run(["python3", str(root / "scripts/render-drm-packages.py"),
        "--version", "9.8.7",
        "--source-url", "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-9.8.7/vibepollo-source-9.8.7.tar.gz",
        "--source-sha", "a" * 64,
        "--libvirtualdisplay-commit", "b" * 40,
        "--cask-url", "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-9.8.7/vibepollo-drm-integration-9.8.7.tar.gz",
        "--cask-sha", "c" * 64,
        "--formula-template", str(formula),
        "--cask-template", str(cask),
        "--formula-output", str(pathlib.Path(temp) / "Formula/vibepollo-drm.rb"),
        "--cask-output", str(pathlib.Path(temp) / "Casks/vibepollo.rb")], check=True)
    rendered_formula = (pathlib.Path(temp) / "Formula/vibepollo-drm.rb").read_text()
    rendered_cask = (pathlib.Path(temp) / "Casks/vibepollo.rb").read_text()
    if "version \"9.8.7\"" not in rendered_formula or ("b" * 40) not in rendered_formula:
        raise SystemExit("DRM Formula release metadata was not rendered")
    if "version \"9.8.7\"" not in rendered_cask or ("c" * 64) not in rendered_cask:
        raise SystemExit("DRM Cask release metadata was not rendered")

cask_text = cask.read_text(encoding="utf-8")
if "systemctl enable" in cask_text or "systemctl start" in cask_text:
    raise SystemExit("The DRM Cask must not enable or start a boot service")
if "mokutil --import" in cask_text or "AUTO_ENROLL" in cask_text:
    raise SystemExit("The DRM Cask must never enroll or auto-enroll Secure Boot keys")
if "/var/lib/vibepollo/drm/keys/mok.key" not in cask_text or "/var/lib/vibepollo/drm/keys/MOK.der" not in cask_text:
    raise SystemExit("The agreed signing-key paths are missing from the Cask")
if "Preserved signing keys" not in (payload_dir / "uninstall.sh").read_text(encoding="utf-8"):
    raise SystemExit("The uninstaller must explicitly preserve signing keys")

print("Vibeshine DRM Formula/Cask syntax, payload, renderer and policy checks passed.")
