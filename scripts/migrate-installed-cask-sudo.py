#!/usr/bin/env python3
"""Restore Homebrew-managed sudo execution for an installed Vibepollo Cask."""

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


def ensure_sudo_true(value: object) -> int:
    """Set sudo:true only on serialized uninstall scripts for uninstall.sh."""
    changed = 0
    if isinstance(value, dict):
        for key, item in list(value.items()):
            if key == "script" and isinstance(item, dict) and contains_uninstall_script(item):
                if item.get("sudo") is not True:
                    item["sudo"] = True
                    changed += 1
            else:
                changed += ensure_sudo_true(item)
    elif isinstance(value, list):
        for item in value:
            changed += ensure_sudo_true(item)
    return changed


def contains_uninstall_script(value: object) -> bool:
    if isinstance(value, str):
        return value.endswith("/uninstall.sh") or value == "uninstall.sh"
    if isinstance(value, dict):
        return any(contains_uninstall_script(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_uninstall_script(item) for item in value)
    return False


def ensure_ruby_uninstall_sudo(source: str) -> tuple[str, int]:
    """Ensure sudo:true only in the installed Cask's uninstall script stanza."""
    lines = source.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines)
              if re.match(r"^[ \t]*uninstall[ \t]+script:[ \t]*\{", line)]
    if len(starts) != 1:
        raise RuntimeError(f"Expected one installed uninstall script stanza; found {len(starts)}")
    start = starts[0]
    indent = re.match(r"^[ \t]*", lines[start]).group(0)
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() == "}" and lines[i][:len(indent)] == indent), None)
    if end is None:
        raise RuntimeError("Installed Cask uninstall script stanza is unterminated")
    for i in range(start + 1, end):
        match = re.match(r"^(?P<indent>[ \t]*)sudo:[ \t]*(?P<value>true|false),?[ \t]*(?:\n)?$", lines[i])
        if match:
            if match.group("value") == "true":
                return source, 0
            newline = "\n" if lines[i].endswith("\n") else ""
            lines[i] = f"{match.group('indent')}sudo: true,{newline}"
            return "".join(lines), 1
    executable = next((i for i in range(start + 1, end)
                       if re.match(r"^[ \t]*executable:", lines[i])), None)
    if executable is None:
        raise RuntimeError("Installed uninstall script has no executable entry")
    item_indent = re.match(r"^[ \t]*", lines[executable]).group(0)
    newline = "\n" if lines[executable].endswith("\n") else ""
    lines.insert(executable + 1, f"{item_indent}sudo: true,{newline}")
    return "".join(lines), 1


def update_installed_cask_definition(path: pathlib.Path) -> tuple[bytes, int]:
    if path.suffix == ".rb":
        original = path.read_text(encoding="utf-8")
        updated, count = ensure_ruby_uninstall_sudo(original)
        return updated.encode("utf-8"), count
    if path.suffix == ".json":
        original = path.read_bytes()
        document = json.loads(original)
        if not isinstance(document, dict):
            raise RuntimeError(f"Installed Cask JSON is not an object: {path}")

        # Recent Homebrew versions may save a minimal installed-Cask JSON
        # snapshot with no artifacts array (or artifacts: null). In that
        # format the uninstall scripts and their sudo flags live in the
        # Caskroom INSTALL_RECEIPT.json, which main() migrates separately.
        artifacts = document.get("artifacts")
        if artifacts is None:
            uninstall_artifacts = document.get("uninstall_artifacts")
            if uninstall_artifacts is None:
                return original, 0
            if not isinstance(uninstall_artifacts, list):
                raise RuntimeError(
                    f"Installed Cask JSON has invalid uninstall_artifacts: {path}"
                )
            count = ensure_sudo_true(uninstall_artifacts)
        elif isinstance(artifacts, list):
            count = ensure_sudo_true(artifacts)
        else:
            raise RuntimeError(f"Installed Cask JSON has invalid artifacts field: {path}")

        if count == 0:
            return original, 0
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



def serialize_receipt(receipt: dict) -> bytes:
    """Serialize a Homebrew receipt as valid JSON with a trailing newline."""
    return (json.dumps(receipt, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def self_test() -> None:
    receipt = {
        "uninstall_artifacts": [
            {"uninstall": [{"script": {"executable": "/home/linuxbrew/Caskroom/vibepollo/2.0.6/uninstall.sh",
                                         "sudo": True, "args": []}}]},
            {"uninstall": [{"delete": ["/var/lib/vibepollo/drm/old-file"]}]},
        ],
        "install_artifacts": [{"script": [{"sudo": True}]}],
    }
    serialized_receipt = serialize_receipt(receipt)
    assert serialized_receipt.endswith(b"\n")
    assert json.loads(serialized_receipt.decode("utf-8")) == receipt

    uninstall = receipt["uninstall_artifacts"]
    assert contains_uninstall_script(uninstall)
    removed = ensure_sudo_true(uninstall)
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
    migrated_ruby, ruby_removed = ensure_ruby_uninstall_sudo(installed_ruby)
    assert ruby_removed == 1
    assert "sudo: true" not in migrated_ruby
    assert 'executable: "/tmp/uninstall.sh"' in migrated_ruby

    with tempfile.TemporaryDirectory(prefix="vibepollo-cask-json-test-") as temporary:
        json_path = pathlib.Path(temporary) / "vibepollo.json"
        # Homebrew 6/7 may write a minimal metadata snapshot with no artifacts.
        minimal_json = b'{\n  "url_specs": {},\n  "artifacts": null\n}\n'
        json_path.write_bytes(minimal_json)
        migrated_json, json_removed = update_installed_cask_definition(json_path)
        assert json_removed == 0
        assert migrated_json == minimal_json

        # Older/full installed metadata can still contain sudo on artifacts.
        full_json = {
            "artifacts": [
                {"uninstall": [{"script": {
                    "executable": "/tmp/uninstall.sh", "sudo": True, "args": []
                }}]}
            ]
        }
        json_path.write_text(json.dumps(full_json))
        migrated_json, json_removed = update_installed_cask_definition(json_path)
        migrated_document = json.loads(migrated_json.decode("utf-8"))
        assert json_removed == 1
        assert "sudo" not in migrated_document["artifacts"][0]["uninstall"][0]["script"]

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
    required_markers = (
        b'[[ "$EUID" -eq 0 ]] || fail "Homebrew must run this uninstaller with sudo: true"',
    )
    forbidden_markers = (b"sudo -v", b"SUDO_ASKPASS", b"sudo -n")
    if any(marker in script for marker in forbidden_markers):
        raise RuntimeError("Published uninstaller must not perform its own sudo escalation")
    if any(marker not in script for marker in required_markers):
        raise RuntimeError("Published uninstaller does not require Homebrew-managed root execution")
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
    updated_caskfile, caskfile_changed = update_installed_cask_definition(installed_caskfile)
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    uninstall_artifacts = receipt.get("uninstall_artifacts")
    if not isinstance(uninstall_artifacts, list) or not contains_uninstall_script(uninstall_artifacts):
        raise RuntimeError("Installed receipt does not contain Vibepollo's uninstall script; refusing migration")

    updated_script = download_uninstaller(payload_url, expected_sha)
    removed = ensure_sudo_true(uninstall_artifacts)
    updated_receipt = serialize_receipt(receipt)

    receipt_backup = receipt_path.with_name("INSTALL_RECEIPT.json.before-homebrew-sudo")
    caskfile_backup = installed_caskfile.with_name(
        installed_caskfile.name + ".before-homebrew-sudo"
    )
    if removed and receipt_backup.exists():
        raise RuntimeError(f"Receipt backup already exists; refusing to overwrite it: {receipt_backup}")
    if caskfile_changed and caskfile_backup.exists():
        raise RuntimeError(f"Installed Cask backup already exists; refusing to overwrite it: {caskfile_backup}")
    if removed:
        shutil.copy2(receipt_path, receipt_backup)
    if caskfile_changed:
        shutil.copy2(installed_caskfile, caskfile_backup)

    script_mode = installed_uninstaller.stat().st_mode & 0o777
    atomic_replace(installed_uninstaller, updated_script, script_mode | 0o100)
    if caskfile_changed:
        caskfile_mode = installed_caskfile.stat().st_mode & 0o777
        atomic_replace(installed_caskfile, updated_caskfile, caskfile_mode)
    if removed:
        receipt_mode = receipt_path.stat().st_mode & 0o777
        atomic_replace(receipt_path, updated_receipt, receipt_mode)

    print(f"Updated installed uninstaller: {installed_uninstaller}", flush=True)
    print(f"Updated installed Cask definition: {installed_caskfile}", flush=True)
    print(
        f"Restored {removed} sudo flag(s) in the Homebrew receipt and "
        f"{caskfile_changed} from the installed Cask definition.",
        flush=True,
    )
    if removed:
        print(f"Original receipt backup: {receipt_backup}", flush=True)
    if caskfile_changed:
        print(f"Original Cask definition backup: {caskfile_backup}", flush=True)
    print("Continuing with Homebrew-managed privileged Cask uninstall...", flush=True)
    return subprocess.run([brew, "uninstall", "--cask", REPOSITORY + "/" + TOKEN]).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, tarfile.TarError, urllib.error.URLError, json.JSONDecodeError) as error:
        print(f"Vibepollo Cask migration: error: {error}", file=sys.stderr)
        raise SystemExit(1)
