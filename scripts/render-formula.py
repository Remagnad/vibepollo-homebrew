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
  depends_on "mold" => :build
  depends_on "node" => :build
  depends_on "pkgconf" => :build
  depends_on "shaderc" => :build
  depends_on "vulkan-headers" => :build

  depends_on "at-spi2-core"
  # The Linux mDNS publisher loads libavahi-client dynamically at runtime.
  depends_on "avahi"
  depends_on "cairo"
  depends_on "gdk-pixbuf"
  depends_on "gtk+3"
  depends_on "harfbuzz"
  depends_on "jpeg-turbo"
  depends_on "libdbusmenu"
  depends_on "libice"
  depends_on "libpng"
  depends_on "libsm"
  depends_on "pango"
  depends_on "webp"
  depends_on "boost"
  depends_on "curl"
  depends_on "gcc@14"
  depends_on "glib"
  depends_on "libayatana-appindicator"
  depends_on "libcap"
  depends_on "libdrm"
  depends_on "libevdev"
  depends_on "libnotify"
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
        # -O2 retains release-grade optimization while substantially reducing C++ compile time.
        "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG",
        "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG",
        "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG",
        "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=mold",
        "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=mold",
        "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=mold",
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
        "-DSUNSHINE_ENABLE_TRAY=ON",
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

      # Homebrew's Linux build sandbox only permits writes to HOMEBREW_CACHE
      # and HOMEBREW_TEMP. Pass an explicit ccache config so the launcher keeps
      # working after Homebrew strips non-whitelisted CCACHE_* environment values.
      ccache = which("ccache")
      if ccache
        ccache_dir = HOMEBREW_CACHE/"vibepollo-ccache"
        ccache_temp_dir = HOMEBREW_CACHE/"vibepollo-ccache-tmp"
        ccache_config = HOMEBREW_CACHE/"vibepollo-ccache.conf"
        ccache_dir.mkpath
        ccache_temp_dir.mkpath
        # Refresh the config because the CI workflow may have created it before the build.
        File.write(ccache_config, <<~CONF)
          cache_dir = #{ccache_dir}
          temporary_dir = #{ccache_temp_dir}
          max_size = 2G
          compiler_check = content
          depend_mode = true
          base_dir = /var/tmp
          hash_dir = false
        CONF
        # Inject CCACHE_CONFIGPATH inside the sandbox instead of passing ccache CLI options.
        ccache_launcher = [which("cmake"), "-E", "env", "CCACHE_CONFIGPATH=#{ccache_config}", ccache].join(";")
        cmake_args += [
          "-DCMAKE_C_COMPILER_LAUNCHER=#{ccache_launcher}",
          "-DCMAKE_CXX_COMPILER_LAUNCHER=#{ccache_launcher}"
        ]
      end

      system "cmake", "-S", buildpath, "-B", buildpath/"build", *cmake_args
      system "cmake", "--build", buildpath/"build", "--parallel", "6"
      system "cmake", "--install", buildpath/"build"

      # Homebrew builds libdbus with its own prefix-specific default system-bus path.
      # Point the Avahi client at the host bus, while respecting explicit user overrides.
      # CMake installs the real binary under its versioned name and makes
      # bin/vibepollo a symlink. Move the real file, not the symlink.
      versioned_binary = bin/"vibepollo-#{version}"
      odie "Versioned Vibepollo executable was not installed by CMake" unless versioned_binary.executable?
      vibepollo_link = bin/"vibepollo"
      odie "Expected CMake to install bin/vibepollo as a symlink" unless vibepollo_link.symlink?
      libexec.mkpath
      versioned_binary.rename(libexec/"vibepollo-bin")
      vibepollo_link.unlink

      (bin/"vibepollo").write <<~SH
        #!/bin/sh
        if [ -z "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]; then
          for bus_socket in /run/dbus/system_bus_socket /var/run/dbus/system_bus_socket; do
            if [ -S "$bus_socket" ]; then
              DBUS_SYSTEM_BUS_ADDRESS="unix:path=$bus_socket"
              export DBUS_SYSTEM_BUS_ADDRESS
              break
            fi
          done
        fi

        launcher_path="$(readlink -f -- "$0")" || exit 126
        case "$launcher_path" in
          */bin/vibepollo) formula_prefix=${launcher_path%/bin/vibepollo} ;;
          *)
            echo "vibepollo: cannot resolve the Homebrew installation path" >&2
            exit 126
            ;;
        esac
        # GTK's icon theme does not normally search the Homebrew prefix.
        # Expose packaged AppIndicator icons while preserving host icon paths.
        xdg_data_dirs=${XDG_DATA_DIRS:-/usr/local/share:/usr/share}
        case ":$xdg_data_dirs:" in
          *":$formula_prefix/share:"*) ;;
          *) xdg_data_dirs="$formula_prefix/share:$xdg_data_dirs" ;;
        esac
        XDG_DATA_DIRS=$xdg_data_dirs
        export XDG_DATA_DIRS
        VIBEPOLLO_ICON_THEME_PATH="$formula_prefix/share/icons"
        export VIBEPOLLO_ICON_THEME_PATH

        exec "$formula_prefix/libexec/vibepollo-bin" "$@"
      SH
      chmod 0755, bin/"vibepollo"

    end
  end

  def caveats
    <<~EOS
      This formula installs the user-space application and its assets only.
      It does not install machine-wide services, privileged helpers, udev rules,
      or kernel modules. Managed virtual displays also require the separate
      driver and machine-integration packages. The C++ AppIndicator tray
      is built into Vibepollo; login autostart is reserved for the Cask integration.
    EOS
  end

  test do
    assert_match "version: #{version}", shell_output("#{bin}/vibepollo --version")
    assert_path_exists libexec/"vibepollo-bin"

    # Exercise the launcher with a harmless stub instead of starting the server.
    launcher_test_prefix = testpath/"launcher-test"
    (launcher_test_prefix/"bin").mkpath
    (launcher_test_prefix/"libexec").mkpath
    launcher_test = launcher_test_prefix/"bin/vibepollo"
    cp bin/"vibepollo", launcher_test
    launcher_test.chmod(0755)
    launcher_stub = launcher_test_prefix/"libexec/vibepollo-bin"
    launcher_stub.write <<~SH
      #!/bin/sh
      printf '%s\\n' "${DBUS_SYSTEM_BUS_ADDRESS:-unset}"
      printf '%s\\n' "${XDG_DATA_DIRS:-unset}"
      printf '%s\\n' "${VIBEPOLLO_ICON_THEME_PATH:-unset}"
      printf '%s\\n' "$@"
    SH
    launcher_stub.chmod(0755)

    host_bus_socket = [
      "/run/dbus/system_bus_socket",
      "/var/run/dbus/system_bus_socket",
    ].find { |socket| File.socket?(socket) }
    expected_default_bus = host_bus_socket ? "unix:path=#{host_bus_socket}" : "unset"
    default_env_output = Utils.safe_popen_read(
      "env", "-u", "DBUS_SYSTEM_BUS_ADDRESS", "-u", "XDG_DATA_DIRS",
      launcher_test.to_s, "--wrapper-test", "argument with spaces"
    )
    expected_default_xdg = "#{launcher_test_prefix}/share:/usr/local/share:/usr/share"
    expected_default_output = [
      "#{expected_default_bus}\n",
      "#{expected_default_xdg}\n",
      "#{launcher_test_prefix}/share/icons\n",
      "--wrapper-test\n",
      "argument with spaces\n"
    ].join
    assert_equal expected_default_output, default_env_output

    custom_bus = "unix:path=/custom/system_bus_socket"
    custom_xdg = "/custom/share:/usr/share"
    custom_env_output = Utils.safe_popen_read(
      "env", "DBUS_SYSTEM_BUS_ADDRESS=#{custom_bus}", "XDG_DATA_DIRS=#{custom_xdg}",
      launcher_test.to_s, "--wrapper-test"
    )
    expected_custom_output = [
      "#{custom_bus}\n",
      "#{launcher_test_prefix}/share:#{custom_xdg}\n",
      "#{launcher_test_prefix}/share/icons\n",
      "--wrapper-test\n"
    ].join
    assert_equal expected_custom_output, custom_env_output
    assert_path_exists share/"vibepollo/web/index.html"
    assert_path_exists share/"vibepollo/web/v2/index.html"
    assert_path_exists share/"icons/hicolor/scalable/apps/io.github.Nonary.vibepollo.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-tray.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-playing.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-pausing.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-locked.svg"
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

