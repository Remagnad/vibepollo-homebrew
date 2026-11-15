class VibepolloDrm < Formula
  desc "Vibeshine HDR virtual-display kernel module"
  homepage "https://github.com/Nonary/libvirtualdisplay"
  version "2.0.6"
  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6/vibepollo-source-2.0.6.tar.gz"
  sha256 "f8bb2fdd872de4deb92020787f31bdf2e6722c4cdc2efae18d8345d2a34bcb5a"
  license "GPL-2.0-only"

  depends_on :linux
  depends_on arch: :x86_64
  depends_on "make" => :build

  LIBVIRTUALDISPLAY_COMMIT = "b6874684d82925d0d76f487d8e4ba3ec71c9721a".freeze
  MINIMUM_KERNEL_VERSION = [6, 16].freeze

  def install
    kernel_release = Utils.safe_popen_read("uname", "-r").strip
    kernel_match = kernel_release.match(/\A([0-9]+)\.([0-9]+)/)
    odie "Could not parse the running kernel version: #{kernel_release}" unless kernel_match

    kernel_version = [kernel_match[1].to_i, kernel_match[2].to_i]
    if (kernel_version <=> MINIMUM_KERNEL_VERSION).negative?
      odie "Vibeshine DRM requires Linux 6.16 or newer; running kernel is #{kernel_release}"
    end

    kernel_build_candidates = [
      Pathname.new("/lib/modules/#{kernel_release}/build"),
      Pathname.new("/usr/lib/modules/#{kernel_release}/build"),
      Pathname.new("/usr/src/kernels/#{kernel_release}"),
    ]
    kernel_build_link = kernel_build_candidates.find do |candidate|
      candidate.directory? &&
        (candidate/"Makefile").file? &&
        (candidate/"scripts/sign-file").executable? &&
        (candidate/"include/generated/autoconf.h").file?
    end
    odie <<~EOS unless kernel_build_link
      Matching kernel development files were not found for #{kernel_release}.
      Install the headers/devel package for the running kernel, then reinstall
      this formula. Expected a kernel build tree containing Makefile,
      include/generated/autoconf.h and scripts/sign-file.
    EOS
    kernel_build = kernel_build_link.realpath

    source_root = buildpath/"Vibepollo-#{version}"
    source_root = buildpath unless source_root.directory?
    module_source = source_root/"third-party/libvirtualdisplay/linux/vibeshine-drm"
    required_sources = %w[
      Makefile
      build-module
      vkms_drv.c
      vibeshine_drm_compat.h
      vibeshine_drm_uapi.h
    ]
    odie "Pinned libvirtualdisplay Vibeshine DRM sources are missing" unless module_source.directory?
    required_sources.each do |source|
      odie "Missing Vibeshine DRM source file: #{source}" unless (module_source/source).file?
    end

    module_build = buildpath/"vibeshine-drm-build"
    cp_r module_source, module_build
    (module_build/"vibeshine_drm_version.h").write(
      "#define VIBESHINE_DRM_VERSION \"#{version}\"\n"
    )

    make_args = []
    kernel_config = kernel_build/".config"
    kernel_config = Pathname.new("/boot/config-#{kernel_release}") unless kernel_config.file?
    if kernel_config.file? && kernel_config.read.include?("CONFIG_CC_IS_CLANG=y")
      odie "The running kernel was built with Clang, but clang is not available in PATH" unless which("clang")

      make_args << "LLVM=1"
    end

    # Match the upstream build helper: Kbuild uses the running kernel's exact
    # prepared headers and switches to LLVM mode for Clang-built kernels.
    make_tool = which("gmake") || which("make")
    odie "GNU make is required to build the kernel module" unless make_tool

    system make_tool, "-C", kernel_build, "M=#{module_build}", *make_args, "modules"

    module_file = module_build/"vibeshine_drm.ko"
    odie "Kbuild completed without vibeshine_drm.ko" unless module_file.file?

    libexec.mkpath
    cp module_file, libexec/"vibeshine_drm.ko"
    chmod 0644, libexec/"vibeshine_drm.ko"

    (libexec/"kernel-release").write("#{kernel_release}\n")
    (libexec/"kernel-build-dir").write("#{kernel_build}\n")
    (libexec/"module-version").write("#{version}\n")
    (libexec/"libvirtualdisplay-commit").write("#{LIBVIRTUALDISPLAY_COMMIT}\n")
  end

  def caveats
    <<~EOS
      This formula builds vibeshine_drm.ko for the currently running kernel.
      It does not sign, install, load or enable the module. The privileged
      installation and signing lifecycle is handled by the vibepollo Cask.
      Kernel headers/devel files matching the running kernel are required.
      Reinstall this formula after changing kernels until DKMS integration
      is added.
    EOS
  end

  test do
    assert_path_exists libexec/"vibeshine_drm.ko"
    assert_equal version.to_s, (libexec/"module-version").read.strip
    assert_equal LIBVIRTUALDISPLAY_COMMIT, (libexec/"libvirtualdisplay-commit").read.strip
    assert_match(/\A[0-9A-Za-z._+-]+\z/, (libexec/"kernel-release").read.strip)
    assert_path_exists (libexec/"kernel-build-dir").read.strip
  end
end
