#!/usr/bin/env python3
"""Static syntax and safety checks for the Linux DRM Formula and Cask."""

from __future__ import annotations
import pathlib, re, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
formula = root / "Formula/vibepollo-drm.rb"
cask = root / "Casks/vibepollo.rb"
for ruby_file in (formula, cask):
    subprocess.run(["ruby", "-c", str(ruby_file)], check=True)
text = cask.read_text(encoding="utf-8")
scripts = re.findall(r'generated_script\s+"([^"]+)",\s+content:\s+<<~SH\n(.*?)\n  SH', text, flags=re.DOTALL)
if len(scripts) != 3:
    raise SystemExit(f"Expected 3 generated shell scripts, found {len(scripts)}")
with tempfile.TemporaryDirectory(prefix="vibepollo-drm-check-") as temp:
    for name, content in scripts:
        path = pathlib.Path(temp) / name
        path.write_text(content + "\n", encoding="utf-8")
        subprocess.run(["bash", "-n", str(path)], check=True)
if "systemctl enable" in text or "systemctl start" in text:
    raise SystemExit("The DRM Cask must not enable or start a boot service")
if "mokutil --import" in text or "AUTO_ENROLL" in text:
    raise SystemExit("The DRM Cask must never enroll or auto-enroll Secure Boot keys")
if "/var/lib/vibepollo/drm/keys/mok.key" not in text:
    raise SystemExit("The agreed private-key path is missing")
if "/var/lib/vibepollo/drm/keys/MOK.der" not in text:
    raise SystemExit("The agreed certificate path is missing")
if "Preserved signing keys" not in text:
    raise SystemExit("The uninstall script must explicitly preserve signing keys")
print("Vibeshine DRM Formula/Cask syntax and policy checks passed.")
