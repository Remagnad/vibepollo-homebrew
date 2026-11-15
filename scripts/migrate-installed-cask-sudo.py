#!/usr/bin/env python3
"""Migrate an installed Vibepollo Cask away from Homebrew's graphical sudo askpass."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request


REPOSITORY = "Remagnad/vibepollo-homebrew"
TOKEN = "vibepollo"


def remove_sudo_true(value: object) -> int:
    """Remove sudo:true from a serialized uninstall-artifact tree in place."""
    removed = 0
    if isinstance(value, dict):
        for key in list(value):
            item = value[key]
            if key == "sudo" and item is True:
                del value[key]
                removed += 1
            else:
                removed += remove_sudo_true(item)
    elif isinstance(value, list):
        for item in value:
            removed += remove_sudo_true(item)
    return removed


def contains_uninstall_script(value: object) -> bool:
    if isinstance(value, str):
        return value.endswith("/uninstall.sh") or value == "uninstall.sh"
    if isinstance(value, dict):
        return any(contains_uninstall_script(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_uninstall_script(item) for item in value)
    return False


def remove_ruby_uninstall_sudo(source: str) -> tuple[str, int]:
    """Remove sudo:true only from the installed Cask's uninstall script stanza."""
    pattern = re.compile(
        r"(?ms)^(?P<indent>[ \\t]*)uninstall[ \\t]+script:[ \\t]*\{"
        r"(?P<body>.*?)^(?P=indent)\}"
    )
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise RuntimeError(
            f"Expected one installed uninstall script stanza in Cask Ruby; found {len(matches)}"
        )
    match = matches[0]
    body, removed = re.subn(
        r"(?m)^[ \\t]*sudo:[ \\t]*true,?[ \\t]*$",
        "",
        match.group("body"),
    )
    return source[:match.start("body")] + body + source[match.end("body"):], removed


def update_installed_cask_definition(path: pathlib.Path) -> tuple[bytes, int]:
    if path.suffix == ".rb":
        original = path.read_text(encoding="utf-8")
        updated, count = remove_ruby_uninstall_sudo(original)
        return updated.encode("utf-8"), count
    if path.suffix == ".json":
        document = json.loads(path.read_text(encoding="utf-8"))
        artifacts = document.get("artifacts")
        if not isinstance(artifacts, list):
            raise RuntimeError(f"Installed Cask JSON has no artifacts array: {path}")
        count = remove_sudo_true(artifacts)
        return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8"), count
    raise RuntimeError(f"Unsupported installed Cask definition: {path}")


def find_installed_cask_definition(caskroom: pathlib.Path, version: str) -> pathlib.Path:
    version_dir = caskroom / ".metadata" / version
    if not version_dir.is_dir() or version_dir.is_symlink():
        raise RuntimeError(f"Installed Cask metadata version directory is missing or unsafe: {version_dir}")
    snapshots = [
        path for path in version_dir.iterdir()
        if path.is_dir() and not path.is_symlink()
    ]
    for snapshot in sorted(snapshots, key=lambda path: path.name, reverse=True):
        casks_dir = snapshot / "Casks"
        if not casks_dir.is_dir() or casks_dir.is_symlink():
            continue
        for suffix in ("rb", "json"):
            candidate = casks_dir / f"{TOKEN}.{suffix}"
            if candidate.is_file() and not candidate.is_symlink():
                return candidate
    raise RuntimeError(f"Installed Cask definition is missing under {version_dir}")



def self_test() -> None:
    receipt = {
        "uninstall_artifacts": [
            {"uninstall": [{"script": {"executable": "/home/linuxbrew/Caskroom/vibepollo/2.0.6/uninstall.sh",
                                         "sudo": True, "args": []}}]},
            {"uninstall": [{"delete": ["/var/lib/vibepollo/drm/old-file"]}]},
        ],
        "install_artifacts": [{"script": [{"sudo": True}]}],
    }
    uninstall = receipt["uninstall_artifacts"]
    assert contains_uninstall_script(uninstall)
    removed = remove_sudo_true(uninstall)
    assert removed == 1
    assert "sudo" not in uninstall[0]["uninstall"][0]["script"]
    assert receipt["install_artifacts"][0]["script"][0]["sudo"] is True

    installed_ruby = """cask "vibepollo" do
  uninstall script: {
    executable: "/tmp/uninstall.sh",
    sudo: true,
  }
end
"""
    migrated_ruby, ruby_removed = remove_ruby_uninstall_sudo(installed_ruby)
    assert ruby_removed == 1
    assert "sudo: true" not in migrated_ruby
    assert 'executable: "/tmp/uninstall.sh"' in migrated_ruby

    with tempfile.TemporaryDirectory(prefix="vibepollo-receipt-test-") as temporary:
        caskroom = pathlib.Path(temporary) / "Caskroom" / "vibepollo"
        (caskroom / ".metadata").mkdir(parents=True)
        receipt_path = caskroom / ".metadata" / "INSTALL_RECEIPT.json"
        receipt_path.write_text("{}")
        assert receipt_path.is_file()
        assert not (caskroom / ".metadata" / "2.0.6" / "INSTALL_RECEIPT.json").exists()
    print("PASS: Homebrew receipt location and installed Cask sudo migration")


def load_release_metadata(tap_root: pathlib.Path) -> tuple[str, str, str]:
    cask_file = tap_root / "Casks" / f"{TOKEN}.rb"
    if not cask_file.is_file() or cask_file.is_symlink():
        raise RuntimeError(f"Cannot read current Cask definition: {cask_file}")
    text = cask_file.read_text(encoding="utf-8")
    version_match = re.search(r'^\s*version "([0-9]+\.[0-9]+\.[0-9]+)"$', text, re.MULTILINE)
    sha_match = re.search(r'^\s*sha256 "([0-9a-f]{64})"$', text, re.MULTILINE)
    if not version_match or not sha_match:
        raise RuntimeError("Current Vibepollo Cask version or SHA-256 is invalid")
    version = version_match.group(1)
    sha256 = sha_match.group(1)
    url = (
        f"https://github.com/{REPOSITORY}/releases/download/vibepollo-{version}/"
        f"vibepollo-drm-integration-{version}.tar.gz"
    )
    return version, sha256, url


def download_uninstaller(url: str, expected_sha256: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "vibepollo-cask-migration"})
    with urllib.request.urlopen(request, timeout=90) as response:
        archive_bytes = response.read()
    actual_sha256 = hashlib.sha256(archive_bytes).hexdigest()
    if actual_sha256 != expected_sha256:
        raise RuntimeError(
            f"Published Cask payload checksum mismatch: expected {expected_sha256}, "
            f"received {actual_sha256}"
        )
    with tempfile.NamedTemporaryFile() as temporary:
        temporary.write(archive_bytes)
        temporary.flush()
        with tarfile.open(temporary.name, mode="r:gz") as archive:
            matches = [member for member in archive.getmembers() if member.name == "uninstall.sh"]
            if len(matches) != 1 or not matches[0].isfile():
                raise RuntimeError("Verified Cask payload does not contain one regular uninstall.sh")
            stream = archive.extractfile(matches[0])
            if stream is None:
                raise RuntimeError("Could not read uninstall.sh from the verified payload")
            script = stream.read()
    if b'exec sudo -- "$0" "$@"' not in script:
        raise RuntimeError("Published uninstaller does not contain the terminal sudo migration")
    return script


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


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return 0
    if len(sys.argv) != 1:
        print(f"Usage: {pathlib.Path(sys.argv[0]).name}", file=sys.stderr)
        return 2
    if os.geteuid() == 0:
        raise RuntimeError("Run this migration as your normal Homebrew user, not through sudo")

    brew = shutil.which("brew")
    if not brew:
        raise RuntimeError("Homebrew was not found in PATH")
    prefix = pathlib.Path(
        subprocess.check_output([brew, "--prefix"], text=True).strip()
    )
    caskroom = prefix / "Caskroom" / TOKEN
    if not caskroom.is_dir() or caskroom.is_symlink():
        print("Vibepollo Cask is not installed; no migration is needed.")
        return 0

    version, expected_sha, payload_url = load_release_metadata(pathlib.Path(__file__).resolve().parents[1])
    version_dirs = [
        path for path in caskroom.iterdir()
        if path.is_dir() and not path.is_symlink() and (path / "uninstall.sh").is_file()
    ]
    if len(version_dirs) != 1:
        raise RuntimeError(
            f"Expected one installed Vibepollo Cask version with uninstall.sh; found {len(version_dirs)}"
        )
    installed_dir = version_dirs[0]
    installed_uninstaller = installed_dir / "uninstall.sh"
    if installed_uninstaller.is_symlink():
        raise RuntimeError(f"Refusing symbolic-link uninstaller: {installed_uninstaller}")

    # Homebrew's Tab receipt lives directly in .metadata. The installed Cask
    # definition is stored separately in .metadata/<version>/<timestamp>/Casks/.
    receipt_path = caskroom / ".metadata" / "INSTALL_RECEIPT.json"
    if not receipt_path.is_file() or receipt_path.is_symlink():
        raise RuntimeError(f"Installed Cask receipt is missing or unsafe: {receipt_path}")
    installed_caskfile = find_installed_cask_definition(caskroom, installed_dir.name)
    updated_caskfile, caskfile_removed = update_installed_cask_definition(installed_caskfile)
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    uninstall_artifacts = receipt.get("uninstall_artifacts")
    if not isinstance(uninstall_artifacts, list) or not contains_uninstall_script(uninstall_artifacts):
        raise RuntimeError("Installed receipt does not contain Vibepollo's uninstall script; refusing migration")

    updated_script = download_uninstaller(payload_url, expected_sha)
    removed = remove_sudo_true(uninstall_artifacts)
    updated_receipt = (json.dumps(receipt, indent=2, ensure_ascii=False) + "\\n").encode("utf-8")

    receipt_backup = receipt_path.with_name("INSTALL_RECEIPT.json.before-terminal-sudo")
    caskfile_backup = installed_caskfile.with_name(
        installed_caskfile.name + ".before-terminal-sudo"
    )
    if removed and receipt_backup.exists():
        raise RuntimeError(f"Receipt backup already exists; refusing to overwrite it: {receipt_backup}")
    if caskfile_removed and caskfile_backup.exists():
        raise RuntimeError(f"Installed Cask backup already exists; refusing to overwrite it: {caskfile_backup}")
    if removed:
        shutil.copy2(receipt_path, receipt_backup)
    if caskfile_removed:
        shutil.copy2(installed_caskfile, caskfile_backup)

    script_mode = installed_uninstaller.stat().st_mode & 0o777
    atomic_replace(installed_uninstaller, updated_script, script_mode | 0o100)
    if caskfile_removed:
        caskfile_mode = installed_caskfile.stat().st_mode & 0o777
        atomic_replace(installed_caskfile, updated_caskfile, caskfile_mode)
    if removed:
        receipt_mode = receipt_path.stat().st_mode & 0o777
        atomic_replace(receipt_path, updated_receipt, receipt_mode)

    print(f"Updated installed uninstaller: {installed_uninstaller}", flush=True)
    print(f"Updated installed Cask definition: {installed_caskfile}", flush=True)
    print(
        f"Removed {removed} sudo flag(s) from the Homebrew receipt and "
        f"{caskfile_removed} from the installed Cask definition.",
        flush=True,
    )
    if removed:
        print(f"Original receipt backup: {receipt_backup}", flush=True)
    if caskfile_removed:
        print(f"Original Cask definition backup: {caskfile_backup}", flush=True)
    print("Continuing with the normal Homebrew Cask uninstall...", flush=True)
    return subprocess.run([brew, "uninstall", "--cask", REPOSITORY + "/" + TOKEN]).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, tarfile.TarError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(f"Vibepollo Cask migration: error: {error}", file=sys.stderr)
        raise SystemExit(1)
