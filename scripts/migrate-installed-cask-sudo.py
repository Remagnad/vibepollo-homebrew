#!/usr/bin/env python3
"""Migrate an installed Vibepollo Cask payload and receipt to current Homebrew uninstall steps."""

from __future__ import annotations

import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


TOKEN = "vibepollo"
FULL_TOKEN = "Remagnad/vibepollo-homebrew/vibepollo"
BACKUP_SUFFIX = ".before-homebrew-askpass-fix"
UNINSTALL_ARTIFACT_KEYS = {"uninstall_preflight_steps", "uninstall_postflight_steps", "uninstall", "zap"}
REQUIRED_PAYLOAD_SCRIPTS = {
    "uninstall.sh": 0o755,
    "uninstall-complete.sh": 0o755,
    "vibepollo-askpass": 0o755,
}
MAX_ARCHIVE_BYTES = 8 * 1024 * 1024
MAX_SCRIPT_BYTES = 512 * 1024


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


def read_verified_payload_archive(archive_bytes: bytes, expected_sha256: str) -> dict[str, bytes]:
    if len(archive_bytes) > MAX_ARCHIVE_BYTES:
        raise RuntimeError("Published Cask payload archive exceeds the migration size limit")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise RuntimeError("Cask payload SHA-256 in the Cask definition is invalid")
    actual_sha256 = hashlib.sha256(archive_bytes).hexdigest()
    if actual_sha256 != expected_sha256:
        raise RuntimeError(
            f"Published Cask payload checksum mismatch: expected {expected_sha256}, got {actual_sha256}"
        )

    result: dict[str, bytes] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as archive:
            members = archive.getmembers()
            for name, expected_mode in REQUIRED_PAYLOAD_SCRIPTS.items():
                matches = [member for member in members if member.name == name]
                if len(matches) != 1:
                    raise RuntimeError(
                        f"Published Cask payload must contain exactly one {name}; found {len(matches)}"
                    )
                member = matches[0]
                if not member.isfile() or member.size <= 0 or member.size > MAX_SCRIPT_BYTES:
                    raise RuntimeError(f"Published Cask payload contains an unsafe {name}")
                if stat.S_IMODE(member.mode) != expected_mode:
                    raise RuntimeError(f"Published Cask payload has unexpected permissions for {name}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise RuntimeError(f"Could not read {name} from the published Cask payload")
                content = stream.read(MAX_SCRIPT_BYTES + 1)
                if len(content) != member.size or len(content) > MAX_SCRIPT_BYTES:
                    raise RuntimeError(f"Published Cask payload has an invalid size for {name}")
                if not content.startswith(b"#!/usr/bin/env bash\n"):
                    raise RuntimeError(f"Published Cask payload has an invalid shell script header for {name}")
                result[name] = content
    except tarfile.TarError as error:
        raise RuntimeError(f"Published Cask payload is not a valid gzip tar archive: {error}") from error
    return result


def install_payload_scripts(version_dir: pathlib.Path, payload_scripts: dict[str, bytes]) -> None:
    if not version_dir.is_dir() or version_dir.is_symlink():
        raise RuntimeError(f"Installed Cask version directory is missing or unsafe: {version_dir}")

    planned: list[tuple[pathlib.Path, bytes, int, bool]] = []
    for name, mode in REQUIRED_PAYLOAD_SCRIPTS.items():
        if name not in payload_scripts:
            raise RuntimeError(f"Verified Cask payload is missing required script: {name}")
        destination = version_dir / name
        if destination.is_symlink():
            raise RuntimeError(f"Refusing to replace symbolic-link Cask payload file: {destination}")
        needs_update = True
        if destination.exists():
            if not destination.is_file():
                raise RuntimeError(f"Refusing to replace non-regular Cask payload file: {destination}")
            current_mode = stat.S_IMODE(destination.stat().st_mode)
            needs_update = destination.read_bytes() != payload_scripts[name] or current_mode != mode
        backup = destination.with_name(destination.name + BACKUP_SUFFIX)
        if needs_update and destination.exists() and (backup.exists() or backup.is_symlink()):
            raise RuntimeError(f"Refusing to overwrite existing payload backup: {backup}")
        planned.append((destination, payload_scripts[name], mode, needs_update))

    # Validate every destination before changing any file, then preserve the old
    # script before atomically replacing it with the SHA-verified release copy.
    for destination, content, mode, needs_update in planned:
        if not needs_update:
            continue
        if destination.exists():
            shutil.copy2(destination, destination.with_name(destination.name + BACKUP_SUFFIX))
        atomic_replace(destination, content, mode)


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


def select_uninstall_artifacts(artifacts: object) -> list:
    if not isinstance(artifacts, list):
        raise RuntimeError("Homebrew did not return a Cask artifact list for Vibepollo")
    selected = [
        entry for entry in artifacts
        if isinstance(entry, dict) and any(key in UNINSTALL_ARTIFACT_KEYS for key in entry)
    ]
    return selected


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
                "command": {"base": "staged_path", "path": "vibepollo-askpass"},
                "stdout_path": {"base": "staged_path", "path": "vibepollo-original-askpass"},
            }, {
                "type": "run",
                "command": {"base": "staged_path", "path": "uninstall.sh"},
                "sudo": True,
                "env": {"SUDO_ASKPASS": "{{staged_path}}/vibepollo-askpass"},
            }],
        }],
    }]
    no_op_uninstall = {"uninstall": [{"script": {"executable": "/tmp/uninstall-complete.sh"}}]}
    mixed_artifacts = [
        {"installer": [{"script": {"executable": "/tmp/install.sh"}}]},
        *artifacts,
        no_op_uninstall,
    ]
    uninstall_artifacts = select_uninstall_artifacts(mixed_artifacts)
    assert uninstall_artifacts == [*artifacts, no_op_uninstall]
    assert validate_artifacts(uninstall_artifacts) == uninstall_artifacts

    scripts = {
        "uninstall.sh": b"#!/usr/bin/env bash\nprintf 'uninstall\\n'\n",
        "uninstall-complete.sh": b"#!/usr/bin/env bash\nprintf 'complete\\n'\n",
        "vibepollo-askpass": b"#!/usr/bin/env bash\nread -r -s password\nprintf '%s\\n' \"$password\"\n",
    }
    archive_buffer = io.BytesIO()
    with tarfile.open(fileobj=archive_buffer, mode="w:gz") as archive:
        for name, content in scripts.items():
            member = tarfile.TarInfo(name)
            member.mode = 0o755
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
    archive_bytes = archive_buffer.getvalue()
    archive_sha = hashlib.sha256(archive_bytes).hexdigest()
    verified_scripts = read_verified_payload_archive(archive_bytes, archive_sha)
    assert verified_scripts == scripts

    with tempfile.TemporaryDirectory(prefix="vibepollo-cask-migration-test-") as temporary:
        root = pathlib.Path(temporary)
        caskroom = root / "Caskroom" / TOKEN
        version_dir = caskroom / "2.0.6"
        version_dir.mkdir(parents=True)
        install_payload_scripts(version_dir, verified_scripts)
        for name, expected in scripts.items():
            installed = version_dir / name
            assert installed.read_bytes() == expected
            assert stat.S_IMODE(installed.stat().st_mode) == 0o755
        # The migration is deliberately safe to rerun after a failed uninstall.
        install_payload_scripts(version_dir, verified_scripts)
        assert not any(version_dir.glob(f"*{BACKUP_SUFFIX}"))

        # Refuse an unexpected symlink without partially updating the directory.
        unsafe_dir = root / "unsafe"
        unsafe_dir.mkdir()
        target = root / "outside"
        target.write_text("do not overwrite", encoding="utf-8")
        (unsafe_dir / "vibepollo-askpass").symlink_to(target)
        try:
            install_payload_scripts(unsafe_dir, verified_scripts)
        except RuntimeError:
            pass
        else:
            raise AssertionError("migration must reject a symlinked askpass helper")
        assert not (unsafe_dir / "uninstall.sh").exists()

        metadata_dir = caskroom / ".metadata" / "2.0.6" / "20261115" / "Casks"
        metadata_dir.mkdir(parents=True)
        json_file = metadata_dir / "vibepollo.json"
        json_file.write_text('{"version":"2.0.6"}', encoding="utf-8")
        assert find_installed_caskfile(caskroom, "2.0.6") == json_file
        rb_file = metadata_dir / "vibepollo.rb"
        rb_file.write_text('cask "vibepollo" do\nend\n', encoding="utf-8")
        try:
            find_installed_caskfile(caskroom, "2.0.6")
        except RuntimeError:
            pass
        else:
            raise AssertionError("ambiguous installed definitions must be rejected")

    try:
        read_verified_payload_archive(archive_bytes, "0" * 64)
    except RuntimeError:
        pass
    else:
        raise AssertionError("migration must reject an unverified payload checksum")
    print("PASS: installed Cask payload and metadata migration checks")

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
    url_match = re.search(r'^  url "([^"]+)"$', source_text, re.MULTILINE)
    sha_match = re.search(r'^  sha256 "([0-9a-f]{64})"$', source_text, re.MULTILINE)
    if not version_match or not url_match or not sha_match:
        raise RuntimeError("Current Cask version, payload URL or SHA-256 is invalid")
    version = version_match.group(1)
    payload_url = url_match.group(1).replace("#{version}", version)
    if not payload_url.startswith("https://github.com/Remagnad/vibepollo-homebrew/releases/download/"):
        raise RuntimeError("Current Cask payload URL is not the expected HTTPS GitHub release asset")
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
    artifacts = validate_artifacts(select_uninstall_artifacts(cask_info.get("artifacts")))

    # The receipt migration alone is not enough: the installed Caskroom still
    # contains the files from the previous payload. Download the exact asset
    # named by the current Cask, verify its SHA-256, and refresh the scripts
    # that Homebrew will execute before changing the installed receipt.
    request = urllib.request.Request(
        payload_url,
        headers={"User-Agent": "vibepollo-homebrew-cask-migration"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload_archive = response.read(MAX_ARCHIVE_BYTES + 1)
    except (OSError, TimeoutError) as error:
        raise RuntimeError(f"Could not download the verified Cask payload {payload_url}: {error}") from error
    payload_scripts = read_verified_payload_archive(payload_archive, sha_match.group(1))
    installed_payload_dir = caskroom / version
    install_payload_scripts(installed_payload_dir, payload_scripts)
    print(f"Installed SHA-verified uninstall scripts into {installed_payload_dir}", flush=True)

    installed_json = {
        "version": version,
        "artifacts": artifacts,
    }
    if isinstance(cask_info.get("url_specs"), dict):
        installed_json["url_specs"] = cask_info["url_specs"]
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
, source_text, re.MULTILINE)
    url_match = re.search(r'^  url "([^"]+)"
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
    artifacts = validate_artifacts(select_uninstall_artifacts(cask_info.get("artifacts")))

    installed_json = {
        "version": version,
        "artifacts": artifacts,
    }
    if isinstance(cask_info.get("url_specs"), dict):
        installed_json["url_specs"] = cask_info["url_specs"]
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
, source_text, re.MULTILINE)
    sha_match = re.search(r'^  sha256 "([0-9a-f]{64})"
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
    artifacts = validate_artifacts(select_uninstall_artifacts(cask_info.get("artifacts")))

    installed_json = {
        "version": version,
        "artifacts": artifacts,
    }
    if isinstance(cask_info.get("url_specs"), dict):
        installed_json["url_specs"] = cask_info["url_specs"]
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
