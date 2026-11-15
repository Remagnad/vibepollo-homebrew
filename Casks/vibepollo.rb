cask "vibepollo" do
  version "2.0.6"
  sha256 "bcb945558752b7acce1d44e50d89c7efe6a29afa868c7982ebb9e25eadee8bd1"

  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-#{version}/vibepollo-drm-integration-#{version}.tar.gz"
  name "Vibepollo"
  desc "Privileged Linux integration for the Vibepollo streaming host"
  homepage "https://github.com/Nonary/Vibepollo"

  depends_on arch: :x86_64
  depends_on formula: [
    "vibepollo-app",
    "vibepollo-drm",
  ]
  depends_on :linux

  installer script: {
    executable: "#{staged_path}/install.sh",
    args:       [
      "#{HOMEBREW_PREFIX}/opt/vibepollo-drm",
      "#{HOMEBREW_PREFIX}/opt/vibepollo-app",
      staged_path,
    ],
  }

  # Run the privileged uninstaller through Homebrew's install-step runner.
  # Its env override is applied to the sudo process itself, so sudo -A uses
  # this terminal-backed helper instead of an inherited graphical askpass.
  uninstall_preflight_steps do
    run "uninstall.sh",
        sudo: true,
        env: {
          "SUDO_ASKPASS" => "{{staged_path}}/vibepollo-askpass",
        }
  end

  caveats <<~EOS
    Before installing, copy your existing Secure Boot key pair to:

      /var/lib/vibepollo/drm/keys/mok.key
      /var/lib/vibepollo/drm/keys/MOK.der

    The key directory must be root-owned and mode 0700. The private key must
    be unencrypted, root-owned, and mode 0600 (or 0400). The DER certificate
    must also be root-owned. The Cask checks that the key pair matches; it
    never generates keys, imports certificates, or requests enrollment.

    The module is signed and installed for the currently running kernel.
    The pool units and broker are installed, but neither service is started
    nor enabled at boot. The control socket is restricted to the desktop user
    who invoked the Cask installer. Start the pool only when needed with:

      sudo systemctl start vibeshine-vkms.service

    This starts the virtual-display pool and loads the module through
    vibeshine-drmctl if it is not already loaded. To stop the pool:

      sudo systemctl stop vibeshine-vkms.service

    To inspect module ownership and status:

      sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl status

    The controller records modules it loads itself. During uninstall, it only
    unloads a matching module that it previously loaded; if the same module
    was loaded outside the controller, unload it manually first. Signing keys
    are preserved when the Cask is uninstalled.
  EOS
end
