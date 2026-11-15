cask "vibepollo" do
  version "2.0.6"
  sha256 "f9f42da568ceb8e513963bb28923a3df30ae37fca653b81820712a5ab66d73fc"

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
      "#{staged_path}/vibeshine-drmctl",
    ],
    sudo:       true,
  }

  uninstall script: {
    executable: "#{staged_path}/uninstall.sh",
    sudo:       true,
  }

  caveats <<~EOS
    Before installing, copy your existing Secure Boot key pair to:

      /var/lib/vibepollo/drm/keys/mok.key
      /var/lib/vibepollo/drm/keys/MOK.der

    The key directory must be root-owned and mode 0700. The private key must
    be unencrypted, root-owned, and mode 0600 (or 0400). The DER certificate
    must also be root-owned. The Cask checks that the key pair matches; it
    never generates keys, imports certificates, or requests enrollment.

    The module is signed and installed for the currently running kernel, but
    it is not loaded and no service is enabled at boot. Load it only when
    needed with:

      sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl load

    The controller records modules it loads itself. During uninstall, it only
    unloads a matching module that it previously loaded; if the same module
    was loaded outside the controller, unload it manually first. Signing keys
    are preserved when the Cask is uninstalled.
  EOS
end
