#!/usr/bin/env python3
"""Render the pinned Homebrew formula for a particular upstream source bundle."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import tarfile


FORMULA_TEMPLATE = '''class VibepolloApp < Formula
  desc "Self-hosted game streaming host with Artemis support"
  homepage "https://github.com/Nonary/Vibepollo"
  url "__SOURCE_URL__"
  sha256 "__SOURCE_SHA__"
  license "GPL-3.0-only"

__BOTTLE_BLOCK__

  # Keep the application compiler/runtime ABI explicit on Linux. The app is
  # linked against Homebrew libraries; GCC's shared C++ runtime is a dependency.
  depends_on "cmake" => :build
  depends_on "jinja2-cli" => :build
  depends_on "ninja" => :build
  depends_on "nlohmann-json" => :build
  depends_on "node" => :build
  depends_on "pkgconf" => :build
  depends_on "shaderc" => :build
  depends_on "vulkan-headers" => :build

  depends_on "boost"
  depends_on "curl"
  depends_on "gcc@14"
  depends_on "glib"
  depends_on "libcap"
  depends_on "libdrm"
  depends_on "libevdev"
  depends_on "libva"
  depends_on "libx11"
  depends_on "libxext"
  depends_on "libxrandr"
  depends_on "mesa"
  depends_on "miniupnpc"
  depends_on "numactl"
  depends_on "openssl@3"
  depends_on "opus"
  depends_on "pipewire"
  depends_on "pulseaudio"
  depends_on "sqlite"
  depends_on "vulkan-loader"
  depends_on "wayland"
  depends_on "zlib-ng-compat"

  # These values are generated from the exact GitHub release tag and commit.
  UPSTREAM_TAG = "__UPSTREAM_TAG__".freeze
  UPSTREAM_COMMIT = "__UPSTREAM_COMMIT__".freeze

  # Homebrew fetches this resource before entering the build sandbox.
  resource "ffmpeg" do
    url "__FFMPEG_URL__"
    sha256 "__FFMPEG_SHA__"
  end

  def install
    ENV["TAG"] = UPSTREAM_TAG
    ENV["COMMIT"] = UPSTREAM_COMMIT
    ENV["BUILD_VERSION"] = version.to_s

    gcc_bin = formula_opt_bin("gcc@14")
    c_compiler = gcc_bin/"gcc-14"
    cxx_compiler = gcc_bin/"g++-14"

    jinja_cli = formula_opt_bin("jinja2-cli")/"jinja2"
    python = Utils.safe_popen_read("head", "-n1", jinja_cli).strip.delete_prefix("#!")
    odie "Could not determine the Jinja-enabled Python interpreter from jinja2-cli" if python.empty?
    odie "Jinja-enabled Python interpreter is missing: #{python}" unless File.executable?(python)
    system python, "-c", "import jinja2"

    resource("ffmpeg").stage do
      ffmpeg_prepared_binaries = Pathname.pwd
      unless (ffmpeg_prepared_binaries/"lib/libavcodec.a").file?
        odie "The pinned FFmpeg resource is missing libavcodec.a"
      end
      unless (ffmpeg_prepared_binaries/"include").directory?
        odie "The pinned FFmpeg resource is missing its include directory"
      end

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
        "-DFFMPEG_PREPARED_BINARIES=#{ffmpeg_prepared_binaries}",
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
        "-DBUILD_VIBESHINE_KWIN_GPU_BRIDGE=OFF"
      ]

      system "cmake", "-S", buildpath, "-B", buildpath/"build", *cmake_args
      system "cmake", "--build", buildpath/"build", "--parallel"
      system "cmake", "--install", buildpath/"build"
    end
  end

  def caveats
    <<~EOS
      This formula installs the user-space application and its assets only.
      It does not install machine-wide services, privileged helpers, udev rules,
      or kernel modules. Managed virtual displays also require the separate
      driver and machine-integration packages.
    EOS
  end

  test do
    assert_match "version: #{version}", shell_output("#{bin}/vibepollo --version")
    assert_path_exists share/"vibepollo/web/index.html"
    assert_path_exists share/"vibepollo/web/v2/index.html"
  end
end
'''


def load_ffmpeg_pin(source_archive: pathlib.Path) -> dict[str, str]:
    try:
        with tarfile.open(source_archive, "r:gz") as bundle:
            matches = [
                member for member in bundle.getmembers()
                if member.isfile()
                and member.name.endswith("/cmake/dependencies/ffmpeg-release.cmake")
            ]
            if len(matches) != 1:
                raise SystemExit("Source archive must contain exactly one ffmpeg-release.cmake")
            source_file = bundle.extractfile(matches[0])
            if source_file is None:
                raise SystemExit("Could not read ffmpeg-release.cmake from source archive.")
            cmake_source = source_file.read().decode("utf-8")
    except (OSError, tarfile.TarError, UnicodeDecodeError) as exc:
        raise SystemExit(f"Could not inspect upstream FFmpeg pin: {exc}") from exc

    def cmake_string(variable: str) -> str:
        values = re.findall(
            r'set\(' + re.escape(variable) + r'\s+"([^"]+)"\)',
            cmake_source,
        )
        if not values:
            raise SystemExit(f"Upstream FFmpeg pin is missing {variable}.")
        return values[-1]

    repository = cmake_string("FFMPEG_GITHUB_REPO")
    tag = cmake_string("FFMPEG_RELEASE_TAG")
    sha256 = cmake_string("FFMPEG_SHA256_Linux_x86_64")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SystemExit(f"Unsafe upstream FFmpeg repository: {repository!r}")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
        raise SystemExit(f"Unsafe upstream FFmpeg release tag: {tag!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise SystemExit("Upstream FFmpeg pin has an invalid Linux x86_64 SHA-256.")

    return {
        "url": f"https://github.com/{repository}/releases/download/{tag}/Linux-x86_64-ffmpeg.tar.gz",
        "sha256": sha256,
    }


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
        formula = record.get("formula", {})
        if formula and formula.get("name") != "vibepollo-app":
            continue

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

            # Match the bottle stanza emitted by brew bottle --json.
            # Never bake the builder's absolute Homebrew prefix into the formula.
            return {"sha256": sha}

    raise SystemExit("Could not find the x86_64_linux bottle metadata in brew bottle JSON.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--source-archive", required=True)
    parser.add_argument("--ffmpeg-url")
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

    ffmpeg = load_ffmpeg_pin(pathlib.Path(args.source_archive))

    bottle_block = ""
    if args.bottle_json:
        if not args.bottle_root_url:
            raise SystemExit("--bottle-root-url is required with --bottle-json")
        bottle = load_bottle(pathlib.Path(args.bottle_json))
        sha_line = f'    sha256 x86_64_linux: "{bottle["sha256"]}"'
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
        "__FFMPEG_URL__": args.ffmpeg_url or ffmpeg["url"],
        "__FFMPEG_SHA__": ffmpeg["sha256"],
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

