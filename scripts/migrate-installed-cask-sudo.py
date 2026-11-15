#!/usr/bin/env python3
"""Migrate an installed Vibepollo Cask to its current Homebrew uninstall definition."""

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
BACKUP_SUFFIX = ".before-askpass-fix"


def contains_uninstall_script(value: object) -> bool:
    if isinstance(value, str):
        return value.endswith("/uninstall.sh") or value == "uninstall.sh"
    if isinstance(value, dict):
        return any(contains_uninstall_script(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_uninstall_script(item) for item in value)
    return False


def set_uninstall_script_sudo(value: object) -> int:
    """Set sudo:true only on serialized uninstall.sh script artifacts."""
    changed = 0
    if isinstance(value, dict):
        for key, item in list(value.items()):
            if key == "script" and isinstance(item, dict) and contains_uninstall_script(item):
                if item.get("sudo") is not True:
                    item["sudo"] = True
                    changed += 1
            else:
                changed += set_uninstall_script_sudo(item)
    elif isinstance(value, list):
        for item in value:
            changed += set_uninstall_script_sudo(item)
    return changed


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
        for suffix in (".rb", ".json"):
            candidate = casks_dir / f"{TOKEN}{suffix}"
            if candidate.is_file() and not candidate.is_symlink():
                candidates.append(candidate)
    if len(candidates) != 1:
        raise RuntimeError(
            f"Expected one installed Cask definition for {version}; found {len(candidates)}"
        )
    return candidates[0]


def self_test() -> None:
    receipt = {
        "uninstall_flight_blocks": False,
        "uninstall_artifacts": [{"uninstall": [{"script": {
            "executable": "/tmp/uninstall.sh", "sudo": False, "args": []
        }}]}],
        "install_artifacts": [{"script": [{"sudo": True}]}],
    }
    assert contains_uninstall_script(receipt["uninstall_artifacts"])
    assert set_uninstall_script_sudo(receipt["uninstall_artifacts"]) == 1
    assert receipt["uninstall_artifacts"][0]["uninstall"][0]["script"]["sudo"] is True
    receipt["uninstall_flight_blocks"] = True
    decoded = json.loads(serialize_json(receipt))
    assert decoded["uninstall_flight_blocks"] is True
    assert decoded["install_artifacts"] == [{"script": [{"sudo": True}]}]

    with tempfile.TemporaryDirectory(prefix="vibepollo-cask-migration-test-") as temporary:
        root = pathlib.Path(temporary)
        version_dir = root / ".metadata" / "2.0.6" / "20261115" / "Casks"
        version_dir.mkdir(parents=True)
        json_file = version_dir / "vibepollo.json"
        json_file.write_text('{"version":"2.0.6"}', encoding="utf-8")
        assert find_installed_caskfile(root, "2.0.6") == json_file
        ruby_file = version_dir / "vibepollo.rb"
        ruby_file.write_text('cask "vibepollo" do\nend\n', encoding="utf-8")
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
    if "uninstall_preflight do" not in source_text or "uninstall_postflight do" not in source_text:
        raise RuntimeError("Current Cask is missing the scoped askpass preflight/postflight blocks")
    if not re.search(r'(?s)uninstall script: \{.*?sudo:\s*true', source_text):
        raise RuntimeError("Current Cask uninstall script must retain sudo: true")

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
    uninstall_artifacts = receipt.get("uninstall_artifacts")
    if not isinstance(uninstall_artifacts, list) or not contains_uninstall_script(uninstall_artifacts):
        raise RuntimeError("Installed receipt has no recorded uninstall.sh artifact; refusing migration")

    set_uninstall_script_sudo(uninstall_artifacts)
    receipt["uninstall_flight_blocks"] = True
    receipt_bytes = serialize_json(receipt)

    ruby_destination = installed_caskfile.with_name(f"{TOKEN}.rb")
    paths_to_backup = [receipt_path]
    if installed_caskfile != ruby_destination:
        paths_to_backup.append(installed_caskfile)
    elif installed_caskfile.read_text(encoding="utf-8") != source_text:
        paths_to_backup.append(installed_caskfile)
    for path in paths_to_backup:
        backup = path.with_name(path.name + BACKUP_SUFFIX)
        if backup.exists() or backup.is_symlink():
            raise RuntimeError(f"Refusing to overwrite existing migration backup: {backup}")

    for path in paths_to_backup:
        shutil.copy2(path, path.with_name(path.name + BACKUP_SUFFIX))

    ruby_mode = (installed_caskfile.stat().st_mode & 0o777) if installed_caskfile.suffix == ".rb" else 0o644
    atomic_replace(ruby_destination, source_text.encode("utf-8"), ruby_mode)
    if installed_caskfile != ruby_destination:
        installed_caskfile.unlink()
    receipt_mode = receipt_path.stat().st_mode & 0o777
    atomic_replace(receipt_path, receipt_bytes, receipt_mode)

    print(f"Installed Homebrew Cask definition updated: {ruby_destination}", flush=True)
    print(f"Installed receipt now records uninstall flight blocks: {receipt_path}", flush=True)
    print("Original installed metadata backups were preserved.", flush=True)
    print("Continuing with Homebrew-managed privileged Cask uninstall...", flush=True)
    return subprocess.run([brew, "uninstall", "--cask", "Remagnad/vibepollo-homebrew/vibepollo"]).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"Vibepollo Cask migration: error: {error}", file=sys.stderr)
        raise SystemExit(1)
