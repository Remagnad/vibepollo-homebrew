class VibepolloApp < Formula
  desc "Self-hosted game streaming host with Artemis support"
  homepage "https://github.com/Nonary/Vibepollo"
  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6/vibepollo-source-2.0.6.tar.gz"
  sha256 "83a6ce7f3d253d837cd141e3f58227a304e74fc750a41ad653aa7ac686cf0b5b"
  license "GPL-3.0-only"

  bottle do
    root_url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6"
    sha256 x86_64_linux: "fcd1968a3e3512c0098d36519aa8d24ac6ee24832eba653b9e0010ef84744552"
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

      system "cmake", "-S", buildpath, "-B", buildpath/"build", *cmake_args
      system "cmake", "--build", buildpath/"build", "--parallel"
      system "cmake", "--install", buildpath/"build"

      # Route the Homebrew Avahi client to the host's system D-Bus socket.
      # Keep the compiled application private and expose a small environment wrapper.
      vibepollo_binary = bin/"vibepollo"
      odie "Vibepollo executable was not installed by CMake" unless vibepollo_binary.executable?
      libexec.mkpath
      vibepollo_binary.rename(libexec/"vibepollo-bin")

      (bin/"vibepollo").write <<~SH
        #!/bin/sh
        if [ -z "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]; then
          export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
        fi
        launcher_path="$(readlink -f -- "$0")"
        formula_prefix="$(dirname -- "$(dirname -- "$launcher_path")")"
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

    # Verify the launcher supplies the host D-Bus address only as a default,
    # preserves a caller-provided address, and forwards command-line arguments.
    launcher_test_prefix = testpath/"launcher-test"
    (launcher_test_prefix/"bin").mkpath
    (launcher_test_prefix/"libexec").mkpath
    launcher_test = launcher_test_prefix/"bin/vibepollo"
    FileUtils.cp bin/"vibepollo", launcher_test
    launcher_test.chmod(0755)
    launcher_stub = launcher_test_prefix/"libexec/vibepollo-bin"
    launcher_stub.write <<~SH
      #!/bin/sh
      printf '%s\\n' "${DBUS_SYSTEM_BUS_ADDRESS:-unset}"
      printf '%s\\n' "$@"
    SH
    launcher_stub.chmod(0755)

    default_env_output = Utils.safe_popen_read(
      "env", "-u", "DBUS_SYSTEM_BUS_ADDRESS", launcher_test.to_s, "--wrapper-test"
    )
    assert_equal "unix:path=/run/dbus/system_bus_socket\\n--wrapper-test\\n", default_env_output

    custom_bus = "unix:path=/custom/system_bus_socket"
    custom_env_output = Utils.safe_popen_read(
      "env", "DBUS_SYSTEM_BUS_ADDRESS=#{custom_bus}", launcher_test.to_s, "--wrapper-test"
    )
    assert_equal "#{custom_bus}\\n--wrapper-test\\n", custom_env_output
    assert_path_exists share/"vibepollo/web/index.html"
    assert_path_exists share/"vibepollo/web/v2/index.html"
    assert_path_exists bin/"vibepollo-tray"
    assert_path_exists share/"applications/vibepollo-tray.desktop"
    tray_desktop = (share/"applications/vibepollo-tray.desktop").read
    assert_match "Exec=#{opt_bin}/vibepollo-tray", tray_desktop
    assert_match "Icon=io.github.Nonary.vibepollo", tray_desktop
    assert_match "usage:", shell_output("#{bin}/vibepollo-tray --help")
    system Formula["pyside"].python3, "-c", "import PySide6.QtWidgets"
  end
end
