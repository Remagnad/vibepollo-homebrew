#!/usr/bin/env python3
"""Render the DRM Formula and Cask from verified upstream release metadata."""

from __future__ import annotations

import argparse
import pathlib


def replace_line(content: str, prefix: str, replacement: str, label: str) -> str:
    lines = content.splitlines()
    indexes = [index for index, line in enumerate(lines) if line.startswith(prefix)]
    if len(indexes) != 1:
        raise SystemExit(f"Expected exactly one {label}; found {len(indexes)}.")
    lines[indexes[0]] = replacement
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--libvirtualdisplay-commit", required=True)
    parser.add_argument("--cask-url", required=True)
    parser.add_argument("--cask-sha", required=True)
    parser.add_argument("--formula-template", required=True)
    parser.add_argument("--cask-template", required=True)
    parser.add_argument("--formula-output", required=True)
    parser.add_argument("--cask-output", required=True)
    args = parser.parse_args()

    version_parts = args.version.split(".")
    if len(version_parts) != 3 or any(not part.isdigit() for part in version_parts):
        raise SystemExit(f"Invalid stable release version: {args.version!r}")
    if len(args.libvirtualdisplay_commit) != 40 or any(char not in "0123456789abcdef" for char in args.libvirtualdisplay_commit):
        raise SystemExit("Invalid libvirtualdisplay gitlink SHA.")
    for label, value in (("source", args.source_sha), ("Cask payload", args.cask_sha)):
        if len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            raise SystemExit(f"Invalid {label} SHA-256.")
    expected_prefix = "https://github.com/Remagnad/vibepollo-homebrew/releases/download/"
    if not args.source_url.startswith(expected_prefix) or not args.cask_url.startswith(expected_prefix):
        raise SystemExit("Refusing an unexpected release asset URL.")

    formula = pathlib.Path(args.formula_template).read_text(encoding="utf-8")
    formula = replace_line(formula, "  url ", f'  url "{args.source_url}"', "Formula source URL")
    formula = replace_line(formula, "  sha256 ", f'  sha256 "{args.source_sha}"', "Formula source SHA-256")
    formula = replace_line(formula, "  LIBVIRTUALDISPLAY_COMMIT = ",
                            f'  LIBVIRTUALDISPLAY_COMMIT = "{args.libvirtualdisplay_commit}".freeze',
                            "libvirtualdisplay commit")

    cask = pathlib.Path(args.cask_template).read_text(encoding="utf-8")
    cask = replace_line(cask, "  version ", f'  version "{args.version}"', "Cask version")
    cask = replace_line(cask, "  sha256 ", f'  sha256 "{args.cask_sha}"', "Cask payload SHA-256")
    expected_cask_url = (f"https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-{args.version}/"
                         f"vibepollo-drm-integration-{args.version}.tar.gz")
    if args.cask_url != expected_cask_url:
        raise SystemExit("Cask payload URL does not match the versioned release asset.")
    if '  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-#{version}/vibepollo-drm-integration-#{version}.tar.gz"' not in cask:
        raise SystemExit("Cask template URL must remain version-interpolated for Homebrew audit.")

    formula_output = pathlib.Path(args.formula_output)
    cask_output = pathlib.Path(args.cask_output)
    formula_output.parent.mkdir(parents=True, exist_ok=True)
    cask_output.parent.mkdir(parents=True, exist_ok=True)
    formula_output.write_text(formula, encoding="utf-8")
    cask_output.write_text(cask, encoding="utf-8")
    print(f"Rendered {formula_output}")
    print(f"Rendered {cask_output}")


if __name__ == "__main__":
    main()
