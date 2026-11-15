class VibepolloApp < Formula
  desc "Self-hosted game streaming host with Artemis support"
  homepage "https://github.com/Nonary/Vibepollo"
  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6/vibepollo-source-2.0.6.tar.gz"
  sha256 "e36e8a684063832255bfd7f9826b032ce314d2479ccfb6b19ebafc0173327ad1"
  license "GPL-3.0-only"

  bottle do
    root_url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6"
    sha256 x86_64_linux: "1d6299b69037db3a257838575ebb657a00185669233fd5ef0c0fc57e107ec32b"
  end

  # Keep the application compiler/runtime ABI explicit on Linux. The app is
  # linked against Homebrew libraries; GCC's shared C++ runtime is a dependency.
  depends_on "cmake" => :build
  depends_on "jinja2-cli" => :build
  depends_on "mold" => :build
  depends_on "ninja" => :build
  depends_on "nlohmann-json" => :build
  # Matches Vibepollo upstream Linux release policy: CUDA 12.9.1 with Pascal support.
  # CUDA is a source-build toolchain, not a bottle install dependency; keeping the
  # external tap out of depends_on lets users pour the published bottle directly.
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
  depends_on "sqlite"
  depends_on "vulkan-loader"
  depends_on "wayland"
  depends_on "webp"
  depends_on "zlib-ng-compat"

  # These values are generated from the exact GitHub release tag and commit.
  UPSTREAM_TAG = "2.0.6".freeze
  UPSTREAM_COMMIT = "5e6ed8594184212d429bb093d7fd47904c9a6fa6".freeze

  # Minimal pinned NVIDIA compiler/runtime components used only for source builds.
  CUDA_VERSION = "12.9".freeze

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

    # CI stages only the pinned NVIDIA build components outside the Homebrew Cellar.
    # This keeps the full multi-gigabyte CUDA Toolkit out of the dependency cache.
    cuda_prefix = HOMEBREW_CACHE/"vibepollo-cuda-12.9.1"
    # Use launch wrappers so nvcc and its helper binaries always receive
    # CUDA_HOME, PATH and LD_LIBRARY_PATH inside Homebrew's build sandbox.
    cuda_nvcc = cuda_prefix/"homebrew/bin/nvcc"
    cuda_cuobjdump = cuda_prefix/"homebrew/bin/cuobjdump"
    odie "Pinned CUDA nvcc is missing: #{cuda_nvcc}" unless cuda_nvcc.executable?
    odie "Pinned CUDA cuobjdump is missing: #{cuda_cuobjdump}" unless cuda_cuobjdump.executable?
    cuda_library_paths = [
      cuda_prefix/"lib64",
      cuda_prefix/"lib",
      cuda_prefix/"nvvm/lib64",
      *Dir[cuda_prefix/"targets/*/lib"].map { |path| Pathname.new(path) },
    ].select(&:directory?).map(&:to_s)
    ENV["CUDA_HOME"] = cuda_prefix.to_s
    ENV["CUDA_PATH"] = cuda_prefix.to_s
    ENV["PATH"] = "#{cuda_prefix}/homebrew/bin:#{cuda_prefix}/bin:#{ENV["PATH"]}"
    ENV["LD_LIBRARY_PATH"] = (
      cuda_library_paths + ENV["LD_LIBRARY_PATH"].to_s.split(":").reject(&:empty?)
    ).uniq.join(":")
    nvcc_version = Utils.safe_popen_read(cuda_nvcc, "--version")
    odie "Expected CUDA Toolkit 12.9, got: #{nvcc_version}" unless nvcc_version.include?("release #{CUDA_VERSION},")

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

      # CMake 4.5 must not guess a default CUDA architecture on a headless CI
      # runner. Bootstrap compiler identification with Pascal; upstream's
      # cuda_architectures.cmake resets this variable after enable_language()
      # and supplies the complete CUDA 12.9 architecture list for the real build.
      cuda_preflight_dir = HOMEBREW_CACHE/"vibepollo-cuda-cmake-preflight"
      cuda_preflight_dir.mkpath
      (cuda_preflight_dir/"CMakeLists.txt").write(<<~CMAKE)
        cmake_minimum_required(VERSION 3.25)
        project(VibepolloCudaToolchainProbe LANGUAGES CXX CUDA)
        add_executable(cuda-toolchain-probe probe.cu)
      CMAKE
      (cuda_preflight_dir/"probe.cu").write(<<~CUDA)
        #include <cuda_runtime.h>
        __global__ void probe_kernel(int *value) {
          if (threadIdx.x == 0) *value = 61;
        }
        int main() { return 0; }
      CUDA
      cuda_preflight_build = cuda_preflight_dir/"build"
      begin
        system "cmake", "-S", cuda_preflight_dir, "-B", cuda_preflight_build, "-G", "Ninja",
               "-DCMAKE_CXX_COMPILER=#{cxx_compiler}",
               "-DCMAKE_CUDA_COMPILER=#{cuda_nvcc}",
               "-DCMAKE_CUDA_HOST_COMPILER=#{cxx_compiler}",
               "-DCMAKE_CUDA_TOOLKIT_ROOT_DIR=#{cuda_prefix}",
               "-DCUDAToolkit_ROOT=#{cuda_prefix}",
               "-DCMAKE_CUDA_ARCHITECTURES=61"
        system "cmake", "--build", cuda_preflight_build, "--parallel", "2"
      rescue
        configure_log = cuda_preflight_build/"CMakeFiles/CMakeConfigureLog.yaml"
        error_log = cuda_preflight_build/"CMakeFiles/CMakeError.log"
        [configure_log, error_log].each do |log|
          next unless log.file?

          puts "CUDA CMake preflight diagnostic: #{log}"
          puts log.read.lines.last(240).join
        end
        homebrew_cmake_log = HOMEBREW_CACHE/"Logs/vibepollo-app/02.cmake.log"
        if homebrew_cmake_log.file?
          puts "Homebrew CMake invocation log (last 240 lines):"
          puts homebrew_cmake_log.read.lines.last(240).join
        end
        puts "CUDA CMake preflight directory retained at: #{cuda_preflight_dir}"
        raise
      else
        rm_r cuda_preflight_dir if cuda_preflight_dir.directory?
      end

      cmake_args = std_cmake_args + [
        "-G", "Ninja",
        "-DCMAKE_C_COMPILER=#{c_compiler}",
        "-DCMAKE_CXX_COMPILER=#{cxx_compiler}",
        # -O2 retains release-grade optimization while substantially reducing C++ compile time.
        "-DCMAKE_C_FLAGS_RELEASE=-O2 -DNDEBUG",
        "-DCMAKE_CXX_FLAGS_RELEASE=-O2 -DNDEBUG",
        "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=mold",
        "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=mold",
        "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=mold",
        # Include linked dependency directories (notably keg-only openssl@3) in installed ELF RUNPATH.
        "-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON",
        "-DCMAKE_INSTALL_BINDIR=bin",
        "-DCMAKE_INSTALL_LIBDIR=lib",
        "-DCMAKE_INSTALL_DATADIR=share",
        "-DSUNSHINE_ASSETS_DIR=share/vibepollo",
        "-DPython_EXECUTABLE=#{python}",
        "-DPYTHON_EXECUTABLE=#{python}",
        "-DGLAD_SKIP_PIP_INSTALL=ON",
        "-DSUNSHINE_BUILD_HOMEBREW=ON",
        "-DFFMPEG_PREPARED_BINARIES=#{ffmpeg_prepared_binaries}",
        "-DSUNSHINE_ENABLE_CUDA=ON",
        "-DSUNSHINE_REQUIRE_CUDA_PASCAL=ON",
        "-DCMAKE_CUDA_COMPILER:PATH=#{cuda_nvcc}",
        # Bootstrap the compiler-ID check on headless runners; the upstream
        # CUDA architecture policy replaces this after enable_language(CUDA).
        "-DCMAKE_CUDA_ARCHITECTURES=61",
        "-DCMAKE_CUDA_TOOLKIT_ROOT_DIR:PATH=#{cuda_prefix}",
        "-DCUDAToolkit_ROOT:PATH=#{cuda_prefix}",
        "-DCMAKE_CUDA_HOST_COMPILER=#{cxx_compiler}",
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
          "-DCMAKE_CXX_COMPILER_LAUNCHER=#{ccache_launcher}",
        ]
      end

      begin
        system "cmake", "-S", buildpath, "-B", buildpath/"build", *cmake_args
      rescue
        configure_log = buildpath/"build/CMakeFiles/CMakeConfigureLog.yaml"
        if configure_log.file?
          puts "Vibepollo CMake configure log (last 200 lines):"
          puts configure_log.read.lines.last(200).join
        end
        raise
      end
      system "cmake", "--build", buildpath/"build", "--parallel", "6"
      system "cmake", "--install", buildpath/"build"

      # Homebrew builds libdbus with its own prefix-specific default system-bus path.
      # Point the Avahi client at the host bus, while respecting explicit user overrides.
      # CMake installs the real binary under its versioned name and makes
      # bin/vibepollo a symlink. Move the real file, not the symlink.
      versioned_binary = bin/"vibepollo-#{version}"
      odie "Versioned Vibepollo executable was not installed by CMake" unless versioned_binary.executable?
      # Match upstream release validation: the bottle must contain native Pascal sm_61 code.
      cuda_elfs = Utils.safe_popen_read(cuda_cuobjdump, "--list-elf", versioned_binary)
      odie "CUDA build is missing Pascal sm_61 device code" unless cuda_elfs.include?("sm_61.")
      vibepollo_link = bin/"vibepollo"
      odie "Expected CMake to install bin/vibepollo as a symlink" unless vibepollo_link.symlink?
      libexec.mkpath
      versioned_binary.rename(libexec/"vibepollo-bin")
      vibepollo_link.unlink

      launcher_script = Pathname.new(__FILE__).realpath.dirname.parent/"scripts/vibepollo-launcher.sh"
      odie "Vibepollo Homebrew launcher script is missing: #{launcher_script}" unless launcher_script.file?
      cp launcher_script, bin/"vibepollo"
      chmod 0755, bin/"vibepollo"
    end
  end

  def caveats
    <<~EOS
      This formula installs the user-space application and its assets only.
      It does not install machine-wide services, privileged helpers, udev rules,
      or kernel modules. Managed virtual displays also require the separate
      driver and machine-integration packages. This bottle was compiled with
      CUDA Toolkit 12.9.1, but the Toolkit is not an installation dependency;
      a compatible NVIDIA driver is still required for NVIDIA acceleration.
      Source builds use the pinned NVIDIA CUDA 12.9.1 compiler/runtime component archives. The C++ AppIndicator tray
      is built into Vibepollo; login autostart is reserved for the Cask integration.
    EOS
  end

  test do
    assert_match "version: #{version}", shell_output("#{bin}/vibepollo --version")
    assert_path_exists libexec/"vibepollo-bin"

    # The CUDA-enabled Linux build bundles NVIDIA's pinned TrueHDR runtime privately.
    # These SONAMEs are dlopen'ed from this directory, not ELF DT_NEEDED entries.
    truehdr_runtime = lib/"vibeshine/truehdr"
    assert_path_exists truehdr_runtime/"runtime-provenance.txt"
    assert_match "sha256=0252866a7b798a6f92c8543443d88f716e8c5bbc6a7ddd77a2754728dada9fa8",
                 (truehdr_runtime/"runtime-provenance.txt").read
    assert_path_exists truehdr_runtime/"nvidia_vfx.libs/libcudart-256e6409.so.12.9.79"
    %w[
      libnppc.so.12
      libnppial.so.12
      libnppicc.so.12
      libnppidei.so.12
      libnppif.so.12
      libnppig.so.12
      libnppim.so.12
      libnppist.so.12
      libnppitc.so.12
      libcudnn.so.9
      libNVCVImage.so
      libnvngxruntime.so
      libVideoFXLocal.so
      libVideoFX.so
      libnvVFXTrueHDR.so
      libnvidia-ngx-truehdr.so.1.2.3
    ].each do |library|
      assert_path_exists truehdr_runtime/"nvvfx/libs"/library
    end

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
      printf '%s\n' "${LD_PRELOAD:-unset}"
      printf '%s\n' "$@"
    SH
    launcher_stub.chmod(0755)

    host_bus_socket = [
      "/run/dbus/system_bus_socket",
      "/var/run/dbus/system_bus_socket",
    ].find { |socket| File.socket?(socket) }
    expected_default_bus = host_bus_socket ? "unix:path=#{host_bus_socket}" : "unset"
    no_vendor_bin = testpath/"no-vendor-bin"
    no_vendor_bin.mkpath
    fake_ldconfig = no_vendor_bin/"ldconfig"
    fake_ldconfig.write("#!/bin/sh\nexit 0\n")
    fake_ldconfig.chmod(0755)
    no_vendor_path = "#{no_vendor_bin}:#{ENV["PATH"]}"
    default_env_output = Utils.safe_popen_read(
      "env", "-u", "DBUS_SYSTEM_BUS_ADDRESS", "-u", "XDG_DATA_DIRS", "-u", "LD_PRELOAD",
      "PATH=#{no_vendor_path}", launcher_test.to_s, "--wrapper-test", "argument with spaces"
    )
    expected_default_xdg = "#{launcher_test_prefix}/share:/usr/local/share:/usr/share"
    expected_default_output = [
      "#{expected_default_bus}
",
      "#{expected_default_xdg}
",
      "#{launcher_test_prefix}/share/icons
",
      "unset
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
      "env", "-u", "LD_PRELOAD", "PATH=#{no_vendor_path}",
      "DBUS_SYSTEM_BUS_ADDRESS=#{custom_bus}", "XDG_DATA_DIRS=#{custom_xdg}",
      launcher_test.to_s, "--wrapper-test"
    )
    expected_custom_output = [
      "#{custom_bus}
",
      "#{launcher_test_prefix}/share:#{custom_xdg}
",
      "#{launcher_test_prefix}/share/icons
",
      "unset
",
      "--wrapper-test
",
    ].join
    assert_equal expected_custom_output, custom_env_output

    # Test vendor-based host library resolution on CPU-only CI workers.
    # AMD/Intel systems have no NVIDIA EGL vendor module, so Homebrew Mesa stays selected.
    graphics_lib_dir = testpath/"host-graphics-libs"
    graphics_bin_dir = testpath/"host-graphics-bin"
    graphics_lib_dir.mkpath
    graphics_bin_dir.mkpath
    graphics_sonames = %w[
      libEGL_nvidia.so.0
      libEGL.so.1
      libGL.so.1
      libGLX.so.0
      libOpenGL.so.0
      libGLdispatch.so.0
      libgbm.so.1
      libdrm.so.2
    ]
    fixture_source = testpath/"host-graphics-fixture.c"
    fixture_source.write("int vibepollo_host_graphics_fixture(void) { return 0; }
")
    fixture_compiler = formula_opt_bin("gcc@14")/"gcc-14"
    graphics_sonames.each do |soname|
      system fixture_compiler, "-shared", "-fPIC", "-Wl,-soname,#{soname}",
             fixture_source, "-o", graphics_lib_dir/soname
    end
    existing_preload = graphics_lib_dir/"libexisting-preload.so"
    system fixture_compiler, "-shared", "-fPIC", "-Wl,-soname,libexisting-preload.so",
           fixture_source, "-o", existing_preload

    full_cache = graphics_sonames.map do |soname|
      " #{soname} (libc6,x86-64) => #{graphics_lib_dir/soname}"
    end.join("
")
    File.write(fake_ldconfig, "#!/bin/sh
cat <<'CACHE'
#{full_cache}
CACHE
")
    fake_ldconfig.chmod(0755)
    nvidia_test_path = "#{no_vendor_bin}:#{graphics_bin_dir}:#{ENV["PATH"]}"
    selected_test_ldconfig = Utils.safe_popen_read(
      "env", "PATH=#{nvidia_test_path}", "sh", "-c", "command -v ldconfig"
    ).strip
    assert_equal fake_ldconfig.to_s, selected_test_ldconfig

    nvidia_env_output = Utils.safe_popen_read(
      "env", "-u", "DBUS_SYSTEM_BUS_ADDRESS", "-u", "XDG_DATA_DIRS",
      "PATH=#{nvidia_test_path}",
      "LD_PRELOAD=#{existing_preload}",
      launcher_test.to_s, "--wrapper-test"
    )
    expected_nvidia_preload = (
      %w[
        libEGL.so.1
        libGL.so.1
        libGLX.so.0
        libOpenGL.so.0
        libGLdispatch.so.0
        libgbm.so.1
        libdrm.so.2
      ].map { |soname| (graphics_lib_dir/soname).realpath.to_s } + [existing_preload.realpath.to_s]
    ).join(":")
    expected_nvidia_output = [
      "#{expected_default_bus}
",
      "#{expected_default_xdg}
",
      "#{launcher_test_prefix}/share/icons
",
      "#{expected_nvidia_preload}
",
      "--wrapper-test
",
    ].join
    assert_equal expected_nvidia_output, nvidia_env_output

    # A NVIDIA vendor marker without the complete host client stack must not
    # inject a partial set or erase an LD_PRELOAD supplied by the user.
    incomplete_cache = [
      " libEGL_nvidia.so.0 (libc6,x86-64) => #{graphics_lib_dir/"libEGL_nvidia.so.0"}",
      " libEGL.so.1 (libc6,x86-64) => #{graphics_lib_dir/"libEGL.so.1"}",
    ].join("
")
    File.write(fake_ldconfig, "#!/bin/sh
cat <<'CACHE'
#{incomplete_cache}
CACHE
")
    fake_ldconfig.chmod(0755)
    incomplete_output = Utils.safe_popen_read(
      "env", "-u", "DBUS_SYSTEM_BUS_ADDRESS", "-u", "XDG_DATA_DIRS",
      "PATH=#{nvidia_test_path}",
      "LD_PRELOAD=#{existing_preload}",
      launcher_test.to_s, "--wrapper-test"
    )
    expected_incomplete_output = [
      "#{expected_default_bus}
",
      "#{expected_default_xdg}
",
      "#{launcher_test_prefix}/share/icons
",
      "#{existing_preload.realpath}
",
      "--wrapper-test
",
    ].join
    assert_equal expected_incomplete_output, incomplete_output

    assert_path_exists share/"vibepollo/web/index.html"
    assert_path_exists share/"vibepollo/web/v2/index.html"
    assert_path_exists share/"icons/hicolor/scalable/apps/io.github.Nonary.vibepollo.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-tray.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-playing.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-pausing.svg"
    assert_path_exists share/"icons/hicolor/scalable/status/io.github.Nonary.vibepollo-locked.svg"
  end
end
