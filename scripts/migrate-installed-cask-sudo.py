#!/usr/bin/env python3
"""Migrate an installed Vibepollo Cask receipt to the current Homebrew uninstall steps."""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


TOKEN = "vibepollo"
FULL_TOKEN = "Remagnad/vibepollo-homebrew/vibepollo"
BACKUP_SUFFIX = ".before-homebrew-askpass-fix"


def serialize_json(value: dict) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def atomic_replace(path: pathlib.Path, content: bytes, mode: int) -> None:
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def find_installed_caskfile(caskroom: pathlib.Path, version: str) -> pathlib.Path:
    version_dir = caskroom / ".metadata" / version
    if not version_dir.is_dir() or version_dir.is_symlink():
        raise RuntimeError(f"Installed Cask metadata version directory is missing or unsafe: {version_dir}")
    candidates = []
    for timestamp_dir in version_dir.iterdir():
        if not timestamp_dir.is_dir() or timestamp_dir.is_symlink():
            continue
        casks_dir = timestamp_dir / "Casks"
        if not casks_dir.is_dir() or casks_dir.is_symlink():
            continue
        for suffix in (".json", ".rb"):
            candidate = casks_dir / f"{TOKEN}{suffix}"
            if candidate.is_file() and not candidate.is_symlink():
                candidates.append(candidate)
    if len(candidates) != 1:
        raise RuntimeError(
            f"Expected one installed Cask definition for {version}; found {len(candidates)}"
        )
    return candidates[0]


def validate_artifacts(artifacts: object) -> list:
    if not isinstance(artifacts, list):
        raise RuntimeError("Homebrew did not return an uninstall artifact list for Vibepollo")
    preflight = [
        entry.get("uninstall_preflight_steps")
        for entry in artifacts
        if isinstance(entry, dict) and "uninstall_preflight_steps" in entry
    ]
    if len(preflight) != 1 or not isinstance(preflight[0], list):
        raise RuntimeError("Current Cask metadata does not contain exactly one uninstall_preflight_steps artifact")
    serialized = json.dumps(preflight[0])
    required = ('"sudo": true', '"SUDO_ASKPASS"', "vibepollo-askpass", "vibepollo-original-askpass", "uninstall.sh")
    if any(marker not in serialized for marker in required):
        raise RuntimeError("Current Homebrew uninstall step is missing sudo or the terminal askpass override")
    return artifacts


def self_test() -> None:
    artifacts = [{
        "uninstall_preflight_steps": [{
            "steps": [{
                "type": "run",
                "command": {"base": "staged_path", "path": "uninstall.sh"},
                "sudo": True,
                "env": {"SUDO_ASKPASS": "{{staged_path}}/vibepollo-askpass"},
            }],
        }],
    }]
    assert validate_artifacts(artifacts) == artifacts
    with tempfile.TemporaryDirectory(prefix="vibepollo-cask-migration-test-") as temporary:
        root = pathlib.Path(temporary)
        casks_dir = root / ".metadata" / "2.0.6" / "20261115" / "Casks"
        casks_dir.mkdir(parents=True)
        json_file = casks_dir / "vibepollo.json"
        json_file.write_text('{"version":"2.0.6"}', encoding="utf-8")
        assert find_installed_caskfile(root, "2.0.6") == json_file
        rb_file = casks_dir / "vibepollo.rb"
        rb_file.write_text('cask "vibepollo" do\nend\n', encoding="utf-8")
        try:
            find_installed_caskfile(root, "2.0.6")
        except RuntimeError:
            pass
        else:
            raise AssertionError("ambiguous installed definitions must be rejected")
    print("PASS: installed Cask migration checks")


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return 0
    if len(sys.argv) != 1:
        print(f"Usage: {pathlib.Path(sys.argv[0]).name}", file=sys.stderr)
        return 2
    if os.geteuid() == 0:
        raise RuntimeError("Run this migration as your normal Homebrew user, not through sudo")

    tap_root = pathlib.Path(__file__).resolve().parents[1]
    cask_source = tap_root / "Casks" / f"{TOKEN}.rb"
    if not cask_source.is_file() or cask_source.is_symlink():
        raise RuntimeError(f"Current Cask definition is missing or unsafe: {cask_source}")
    source_text = cask_source.read_text(encoding="utf-8")
    version_match = re.search(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', source_text, re.MULTILINE)
    if not version_match:
        raise RuntimeError("Current Cask version is invalid")
    version = version_match.group(1)
    if "uninstall_preflight_steps do" not in source_text or '"SUDO_ASKPASS" => "{{staged_path}}/vibepollo-askpass"' not in source_text:
        raise RuntimeError("Current Cask is missing the Homebrew-native terminal askpass uninstall step")

    brew = shutil.which("brew")
    if not brew:
        raise RuntimeError("Homebrew was not found in PATH")
    prefix = pathlib.Path(subprocess.check_output([brew, "--prefix"], text=True).strip())
    caskroom = prefix / "Caskroom" / TOKEN
    if not caskroom.is_dir() or caskroom.is_symlink():
        print("Vibepollo Cask is not installed; no migration is needed.")
        return 0

    installed_versions = [
        path.name for path in caskroom.iterdir()
        if path.is_dir() and not path.is_symlink() and path.name != ".metadata"
    ]
    if installed_versions != [version]:
        raise RuntimeError(
            f"Expected exactly Vibepollo {version} installed; found {installed_versions}"
        )

    installed_caskfile = find_installed_caskfile(caskroom, version)
    receipt_path = caskroom / ".metadata" / "INSTALL_RECEIPT.json"
    if not receipt_path.is_file() or receipt_path.is_symlink():
        raise RuntimeError(f"Installed Cask receipt is missing or unsafe: {receipt_path}")
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    if not isinstance(receipt, dict):
        raise RuntimeError("Installed Cask receipt is not a JSON object")

    # Ask Homebrew itself to serialize the current Cask's uninstall artifacts.
    # This keeps the installed receipt in the exact schema expected by that
    # Homebrew version, including normalized install-step path specifications.
    info = subprocess.check_output(
        [brew, "info", "--json=v2", "--cask", FULL_TOKEN],
        text=True,
    )
    document = json.loads(info)
    casks = document.get("casks") if isinstance(document, dict) else None
    if not isinstance(casks, list) or len(casks) != 1 or not isinstance(casks[0], dict):
        raise RuntimeError("Homebrew did not return exactly one Vibepollo Cask metadata record")
    cask_info = casks[0]
    if str(cask_info.get("version")) != version:
        raise RuntimeError("Homebrew's current Cask version does not match the installed Cask version")
    artifacts = validate_artifacts(cask_info.get("artifacts"))

    installed_json = {
        "version": version,
        "artifacts": artifacts,
    }
    old_json = {}
    if installed_caskfile.suffix == ".json":
        old_json = json.loads(installed_caskfile.read_text(encoding="utf-8"))
        if isinstance(old_json, dict) and isinstance(old_json.get("url_specs"), dict):
            installed_json["url_specs"] = old_json["url_specs"]
    elif installed_caskfile.suffix != ".rb":
        raise RuntimeError(f"Unsupported installed Cask metadata file: {installed_caskfile}")

    receipt["uninstall_artifacts"] = artifacts
    receipt["uninstall_flight_blocks"] = False
    receipt_bytes = serialize_json(receipt)
    installed_bytes = serialize_json(installed_json)
    json_destination = installed_caskfile.with_name(f"{TOKEN}.json")

    receipt_needs_update = receipt_path.read_bytes() != receipt_bytes
    caskfile_needs_update = installed_caskfile != json_destination or installed_caskfile.read_bytes() != installed_bytes
    paths_to_backup = []
    if receipt_needs_update:
        paths_to_backup.append(receipt_path)
    if caskfile_needs_update:
        paths_to_backup.append(installed_caskfile)
    for path in paths_to_backup:
        backup = path.with_name(path.name + BACKUP_SUFFIX)
        if backup.exists() or backup.is_symlink():
            raise RuntimeError(f"Refusing to overwrite existing migration backup: {backup}")

    for path in paths_to_backup:
        shutil.copy2(path, path.with_name(path.name + BACKUP_SUFFIX))

    if caskfile_needs_update:
        mode = (installed_caskfile.stat().st_mode & 0o777) if installed_caskfile.suffix == ".json" else 0o644
        atomic_replace(json_destination, installed_bytes, mode)
        if installed_caskfile != json_destination:
            installed_caskfile.unlink()
    if receipt_needs_update:
        atomic_replace(receipt_path, receipt_bytes, receipt_path.stat().st_mode & 0o777)

    print(f"Updated Homebrew's installed Cask metadata: {json_destination}", flush=True)
    print(f"Updated Homebrew's uninstall receipt: {receipt_path}", flush=True)
    print("Original metadata backups were preserved.", flush=True)
    print("Continuing with Homebrew-managed privileged Cask uninstall...", flush=True)
    return subprocess.run([brew, "uninstall", "--cask", FULL_TOKEN]).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Vibepollo Cask migration: error: {error}", file=sys.stderr)
        raise SystemExit(1)
