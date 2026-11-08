#!/usr/bin/env python3
"""Render the pinned Homebrew formula for a particular upstream source bundle."""

from __future__ import annotations

import argparse
import json
import pathlib


FORMULA_TEMPLATE = '''class VibepolloApp < Formula
  desc "Self-hosted game streaming host with Artemis support"
  homepage "https://github.com/Nonary/Vibepollo"
  license "GPL-3.0-only"
  version "__VERSION__"
  url "__SOURCE_URL__"
  sha256 "__SOURCE_SHA__"

  # Keep the application compiler/runtime ABI explicit on Linux. The app is
  # linked against Homebrew libraries; GCC's shared C++ runtime is a dependency.
  depends_on "gcc@14"

  depends_on "boost"
  depends_on "curl"
  depends_on "glib"
  depends_on "libcap"
  depends_on "libdrm"
  depends_on "libevdev"
  depends_on "libva"
  depends_on "libx11"
  depends_on "miniupnpc"
  depends_on "mesa"
  depends_on "numactl"
  depends_on "openssl@3"
  depends_on "opus"
  depends_on "pipewire"
  depends_on "pulseaudio"
  depends_on "sqlite"
  depends_on "vulkan-loader"
  depends_on "wayland"

  depends_on "cmake" => :build
  depends_on "jinja2-cli" => :build
  depends_on "ninja" => :build
  depends_on "node" => :build
  depends_on "nlohmann-json" => :build
  depends_on "pkgconf" => :build
  depends_on "shaderc" => :build
  depends_on "vulkan-headers" => :build

  # These values are generated from the exact GitHub release tag and commit.
  UPSTREAM_TAG = "__UPSTREAM_TAG__"
  UPSTREAM_COMMIT = "__UPSTREAM_COMMIT__"

__BOTTLE_BLOCK__
  def install
    ENV["TAG"] = UPSTREAM_TAG
    ENV["COMMIT"] = UPSTREAM_COMMIT
    ENV["BUILD_VERSION"] = version.to_s

    gcc_bin = Formula["gcc@14"].opt_bin
    c_compiler = gcc_bin/"gcc-14"
    cxx_compiler = gcc_bin/"g++-14"

    jinja_cli = Formula["jinja2-cli"].opt_bin/"jinja2"
    python = Utils.safe_popen_read("head", "-n1", jinja_cli).strip.delete_prefix("#!")
    odie "Could not determine the Jinja-enabled Python interpreter from jinja2-cli" if python.empty?
    odie "Jinja-enabled Python interpreter is missing: #{python}" unless File.executable?(python)
    system python, "-c", "import jinja2"

    cmake_args = std_cmake_args + [
      "-G", "Ninja",
      "-DCMAKE_C_COMPILER=#{c_compiler}",
      "-DCMAKE_CXX_COMPILER=#{cxx_compiler}",
      "-DCMAKE_INSTALL_BINDIR=bin",
      "-DCMAKE_INSTALL_LIBDIR=lib",
      "-DCMAKE_INSTALL_DATADIR=share",
      "-DSUNSHINE_ASSETS_DIR=share/vibepollo",
      "-DPython_EXECUTABLE=#{python}",
      "-DPYTHON_EXECUTABLE=#{python}",
      "-DGLAD_SKIP_PIP_INSTALL=ON",
      "-DSUNSHINE_BUILD_HOMEBREW=ON",
      "-DSUNSHINE_ENABLE_CUDA=OFF",
      "-DSUNSHINE_ENABLE_DRM=OFF",
      "-DSUNSHINE_ENABLE_TRAY=OFF",
      "-DSUNSHINE_ENABLE_PYROWAVE=ON",
      "-DSUNSHINE_ENABLE_VAAPI=ON",
      "-DSUNSHINE_ENABLE_VULKAN=ON",
      "-DSUNSHINE_ENABLE_WAYLAND=ON",
      "-DSUNSHINE_ENABLE_X11=ON",
      "-DSUNSHINE_ENABLE_KWIN=ON",
      "-DSUNSHINE_ENABLE_PORTAL=ON",
      "-DSUNSHINE_ENABLE_GAMESCOPE=ON",
      "-DSUNSHINE_SYSTEM_VULKAN_HEADERS=ON",
      "-DBUILD_TESTS=OFF",
      "-DBUILD_DOCS=OFF",
      "-DBOOST_USE_STATIC=OFF",
      "-DBUILD_VIRTUALDISPLAY_TOOLS=OFF",
      "-DBUILD_VIRTUALDISPLAY_PROBE=OFF",
      "-DBUILD_VIRTUALDISPLAY_VULKAN_LAYER=OFF",
      "-DBUILD_VIBESHINE_KWIN_GPU_BRIDGE=OFF",
    ]

    system "cmake", "-S", ".", "-B", "build", *cmake_args
    system "cmake", "--build", "build", "--parallel"
    system "cmake", "--install", "build"
  end

  def caveats
    <<~EOS
      This formula installs the user-space application and its assets only.
      It does not install machine-wide services, privileged helpers, udev rules,
      or kernel modules. Those are intentionally handled by separate integration
      packages.
    EOS
  end

  test do
    assert_match "version: #{version}", shell_output("#{bin}/vibepollo --version")
    assert_predicate share/"vibepollo/web/index.html", :exist?
    assert_predicate share/"vibepollo/web/v2/index.html", :exist?
  end
end
'''


def load_bottle(path: pathlib.Path) -> dict:
    raw = json.loads(path.read_text(encoding="utf-8"))

    # Current `brew bottle --json` output is keyed by formula full name:
    # {"vibepollo-app": {"formula": {...}, "bottle": {"cellar": "...",
    # "tags": {"x86_64_linux": {"sha256": "...", ...}}}}}
    if isinstance(raw, dict) and "bottle" not in raw:
        records = [value for value in raw.values() if isinstance(value, dict)]
    elif isinstance(raw, list):
        records = raw
    else:
        records = [raw]

    for record in records:
        bottle = record.get("bottle", {})
        tags = bottle.get("tags", {})
        entry = tags.get("x86_64_linux") if isinstance(tags, dict) else None

        # Retain support for older bottle JSON shapes for easier local testing.
        if entry is None:
            stable = bottle.get("stable", bottle)
            files = stable.get("files", stable.get("tags", {}))
            if isinstance(files, dict):
                entry = files.get("x86_64_linux")
                if entry is None:
                    entry = next(
                        (value for key, value in files.items() if "x86_64_linux" in key),
                        None,
                    )

        if entry:
            sha = entry.get("sha256")
            if not sha or not __import__("re").fullmatch(r"[0-9a-f]{64}", sha):
                raise SystemExit("Bottle JSON has no valid x86_64_linux SHA-256.")
            return {
                "sha256": sha,
                "cellar": entry.get("cellar") or bottle.get("cellar"),
            }

    raise SystemExit("Could not find the x86_64_linux bottle metadata in brew bottle JSON.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--bottle-json")
    parser.add_argument("--bottle-root-url")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if not __import__("re").fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        raise SystemExit(f"Unsupported stable version: {args.version}")
    if not __import__("re").fullmatch(r"[0-9a-f]{40}", args.commit):
        raise SystemExit(f"Invalid upstream commit SHA: {args.commit}")
    if not __import__("re").fullmatch(r"[0-9a-f]{64}", args.source_sha):
        raise SystemExit("Invalid source bundle SHA-256.")

    bottle_block = ""
    if args.bottle_json:
        if not args.bottle_root_url:
            raise SystemExit("--bottle-root-url is required with --bottle-json")
        bottle = load_bottle(pathlib.Path(args.bottle_json))
        cellar = bottle["cellar"]
        if cellar in (":any", ":any_skip_relocation"):
            sha_line = f'  sha256 cellar: {cellar}, x86_64_linux: "{bottle["sha256"]}"'
        elif cellar:
            escaped_cellar = str(cellar).replace('"', '\\"')
            sha_line = f'  sha256 cellar: "{escaped_cellar}", x86_64_linux: "{bottle["sha256"]}"'
        else:
            sha_line = f'  sha256 x86_64_linux: "{bottle["sha256"]}"'
        bottle_block = (
            "  bottle do\n"
            f'    root_url "{args.bottle_root_url.rstrip("/")}"\n'
            f"{sha_line}\n"
            "  end\n"
        )

    replacements = {
        "__VERSION__": args.version,
        "__UPSTREAM_TAG__": args.tag,
        "__UPSTREAM_COMMIT__": args.commit,
        "__SOURCE_URL__": args.source_url,
        "__SOURCE_SHA__": args.source_sha,
        "__BOTTLE_BLOCK__": bottle_block.rstrip(),
    }
    rendered = FORMULA_TEMPLATE
    for marker, value in replacements.items():
        rendered = rendered.replace(marker, value)
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    print(f"Rendered {output}")


if __name__ == "__main__":
    main()
