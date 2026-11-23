cask "vibepollo" do
  version "2.18.9,7ac855faf496-f850fbd777a7"
  sha256 "f850fbd777a7417a6928d24aefc292f21bcd373fc9423a08945aa1d81191ac67"

  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-#{version.csv.first}/vibepollo-drm-integration-#{version.csv.first}.tar.gz"
  name "Vibepollo"
  desc "Privileged Linux integration for the Vibepollo streaming host"
  homepage "https://github.com/Nonary/Vibepollo"

  depends_on arch: :x86_64
  depends_on formula: [
    "vibepollo-app",
    "vibepollo-drm",
  ]
  depends_on :linux

  # The privileged step runs before the installer artifact and delegates
  # elevation and terminal authentication to Homebrew.
  installer script: {
    executable: "#{staged_path}/install-complete.sh",
  }

  # Give sudo the same terminal-backed askpass helper used at uninstall,
  # instead of asking install.sh to invoke sudo from inside the Cask runner.
  preflight_steps do
    run "install.sh",
        base: :staged_path,
        args: [
          "{{HOMEBREW_PREFIX}}/opt/vibepollo-drm",
          "{{HOMEBREW_PREFIX}}/opt/vibepollo-app",
          "{{staged_path}}",
        ],
        sudo: true,
        env:  { "SUDO_ASKPASS" => "{{staged_path}}/vibepollo-askpass" }
  end

  # Run the privileged uninstaller through Homebrew's install-step runner.
  # Its env override is applied to the sudo process itself, so sudo -A uses
  # this terminal-backed helper instead of an inherited graphical askpass.
  uninstall_preflight_steps do
    # Keep sudo authentication inside Homebrew while using the invoking
    # terminal instead of an inherited graphical SUDO_ASKPASS program.
    run "uninstall.sh",
        base: :staged_path,
        sudo: true,
        env:  { "SUDO_ASKPASS" => "{{staged_path}}/vibepollo-askpass" }
  end

  uninstall script: {
    executable: "#{staged_path}/uninstall-complete.sh",
  }

  caveats <<~EOS
    Before installing, copy your existing Secure Boot key pair to:

      /var/lib/vibepollo/drm/keys/mok.key
      /var/lib/vibepollo/drm/keys/MOK.der

    The key directory must be root-owned and mode 0700. The private key must
    be unencrypted, root-owned, and mode 0600 (or 0400). The DER certificate
    must also be root-owned. The Cask checks that the key pair matches; it
    never generates keys, imports certificates, or requests enrollment.

    The module is signed and installed for the currently running kernel.
    The pool units and broker are installed but remain stopped and
    disabled at boot by default. Starting Vibepollo from its Homebrew
    launcher starts the managed pool on demand through graphical
    authorization. These graphical controls require PolicyKit's
    /usr/bin/pkexec and an active graphical authentication agent; without
    them, use the manual systemctl commands below.
    The tray menu also provides "Quit and stop services" and the opt-in
    "Start with system" setting. Autostart remains disabled
    until you enable it from the tray. The control socket is restricted to
    the desktop user who invoked the Cask installer, through that user's
    private primary group while keeping the socket itself root-owned.

    Physical monitor capture through KMS is enabled in the app build and uses
    a separate root-owned helper with only CAP_SYS_ADMIN in its permitted
    capability set; the main Vibepollo process receives no capabilities.
    The host must provide the libdrm and libcap runtime libraries and the
    setcap/getcap utilities for the Cask to install and verify this helper.

    On systems with an NVIDIA PCI GPU, the Cask also installs the upstream
    KWin GPU-association bridge as a root-owned shared library with the
    secure-loader trust bit, plus user-service drop-ins for KWin and Plasma.
    It uses the host libdrm, libgbm and C++ runtime; these must be installed by
    your distribution. The bridge is skipped on systems without NVIDIA GPUs.
    On immutable systems, the library is exposed through systemd-sysext when
    available. Log out and back in after installation or upgrade so KWin
    starts with the new bridge configuration.

    For manual administration, the pool can still be managed with:

      sudo systemctl start vibeshine-vkms.service
      sudo systemctl stop vibeshine-vkms.service

    To inspect module ownership and status:

      sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl status

    The controller records modules it loads itself. During an upgrade or
    uninstall, the Cask refuses to remove integration files while any
    vibeshine_drm module remains loaded, including one loaded outside the
    controller. Close virtual displays and retry; if the compositor still
    holds the module, reboot and retry. Signing keys are preserved.
  EOS
end
