class VibepolloApp < Formula
  desc "Self-hosted game streaming host with Artemis support"
  homepage "https://github.com/Nonary/Vibepollo"
  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6/vibepollo-source-2.0.6.tar.gz"
  sha256 "848ed79215c1b65405d872e3be523127080da3e4cfd2fadf5924dca5e3646358"
  license "GPL-3.0-only"

  bottle do
    root_url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6"
    sha256 x86_64_linux: "d51b660e6fedc0e21c6012dc3ed085e8dad4be8a93c7f6c95afa95879885b62c"
  end

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

  depends_on "at-spi2-core"
  # The Linux mDNS publisher loads libavahi-client dynamically at runtime.
  depends_on "avahi"
  depends_on "boost"
  depends_on "cairo"
  depends_on "curl"
  depends_on "gcc@14"
  depends_on "gdk-pixbuf"
  depends_on "glib"
  depends_on "gtk+3"
  depends_on "harfbuzz"
  depends_on "jpeg-turbo"
  depends_on "libayatana-appindicator"
  depends_on "libcap"
  depends_on "libdbusmenu"
  depends_on "libdrm"
  depends_on "libevdev"
  depends_on "libice"
  depends_on "libnotify"
  depends_on "libpng"
  depends_on "libsm"
  depends_on "libva"
  depends_on "libx11"
  depends_on "libxext"
  depends_on "libxrandr"
  depends_on "mesa"
  depends_on "miniupnpc"
  depends_on "numactl"
  depends_on "openssl@3"
  depends_on "opus"
  depends_on "pango"
  depends_on "pipewire"
  depends_on "pulseaudio"
  depends_on "pyside"
  depends_on "sqlite"
  depends_on "vulkan-loader"
  depends_on "wayland"
  depends_on "webp"
  depends_on "zlib-ng-compat"

  # These values are generated from the exact GitHub release tag and commit.
  UPSTREAM_TAG = "2.0.6".freeze
  UPSTREAM_COMMIT = "5e6ed8594184212d429bb093d7fd47904c9a6fa6".freeze

  # Homebrew fetches this resource before entering the build sandbox.
  resource "ffmpeg" do
    url "https://github.com/Nonary/build-deps/releases/download/v2026.516.30821-nonary.1/Linux-x86_64-ffmpeg.tar.gz"
    sha256 "c38e1e87d819560aecbc6e3906702c6e49ef71d3a7d26b3a9e24a69f1819536a"
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
        "-DSUNSHINE_HOMEBREW_TRAY_EXECUTABLE=#{opt_bin}/vibepollo-tray",
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
          base_dir = /var/tmp
          hash_dir = false
        CONF
        # Inject CCACHE_CONFIGPATH inside the sandbox instead of passing ccache CLI options.
        ccache_launcher = [which("cmake"), "-E", "env", "CCACHE_CONFIGPATH=#{ccache_config}", ccache].join(";")
        cmake_args += [
          "-DCMAKE_C_COMPILER_LAUNCHER=#{ccache_launcher}",
          "-DCMAKE_CXX_COMPILER_LAUNCHER=#{ccache_launcher}",
        ]
      end

      system "cmake", "-S", buildpath, "-B", buildpath/"build", *cmake_args
      system "cmake", "--build", buildpath/"build", "--parallel"
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

      tray_script = bin/"vibepollo-tray"
      odie "Homebrew tray companion was not installed by CMake" unless tray_script.executable?
      inreplace tray_script, "#!/usr/bin/python3", "#!#{Formula["pyside"].python3}"
    end
  end

  def caveats
    <<~EOS
      This formula installs the user-space application and its assets only.
      It does not install machine-wide services, privileged helpers, udev rules,
      or kernel modules. Managed virtual displays also require the separate
      driver and machine-integration packages. The Python tray companion is
      included; login autostart is reserved for the Cask integration.
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
      printf '%s\n' "${DBUS_SYSTEM_BUS_ADDRESS:-unset}"
      printf '%s\n' "${XDG_DATA_DIRS:-unset}"
      printf '%s\n' "${VIBEPOLLO_ICON_THEME_PATH:-unset}"
      printf '%s\n' "$@"
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
      "#{expected_default_bus}
",
      "#{expected_default_xdg}
",
      "#{launcher_test_prefix}/share/icons
",
      "--wrapper-test
",
      "argument with spaces
",
    ].join
    assert_equal expected_default_output, default_env_output

    custom_bus = "unix:path=/custom/system_bus_socket"
    custom_xdg = "/custom/share:/usr/share"
    custom_env_output = Utils.safe_popen_read(
      "env", "DBUS_SYSTEM_BUS_ADDRESS=#{custom_bus}", "XDG_DATA_DIRS=#{custom_xdg}",
      launcher_test.to_s, "--wrapper-test"
    )
    expected_custom_output = [
      "#{custom_bus}
",
      "#{launcher_test_prefix}/share:#{custom_xdg}
",
      "#{launcher_test_prefix}/share/icons
",
      "--wrapper-test
",
    ].join
    assert_equal expected_custom_output, custom_env_output
    assert_path_exists share/"vibepollo/web/index.html"
    assert_path_exists share/"vibepollo/web/v2/index.html"
    assert_path_exists bin/"vibepollo-tray"
    assert_path_exists share/"applications/vibepollo-tray.desktop"
    assert_path_exists share/"icons/hicolor/scalable/apps/io.github.Nonary.vibepollo.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-tray.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-playing.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-pausing.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-locked.svg"
    tray_desktop = (share/"applications/vibepollo-tray.desktop").read
    assert_match "Exec=#{opt_bin}/vibepollo-tray", tray_desktop
    assert_match "Icon=io.github.Nonary.vibepollo", tray_desktop
    assert_match "usage:", shell_output("#{bin}/vibepollo-tray --help")
    system Formula["pyside"].python3, "-c", "import PySide6.QtWidgets"
  end
end
