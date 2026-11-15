cask "vibepollo" do
  version "2.0.6"
  sha256 "00bfc91b058f7920307237108ffa19c5b8034c3583c9ac0af04f7f0679c735e3"

  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-#{version}/vibepollo-drm-integration-#{version}.tar.gz"
  name "Vibepollo"
  desc "Privileged Linux integration for the Vibepollo streaming host"
  homepage "https://github.com/Nonary/Vibepollo"

  depends_on :linux
  depends_on arch: :x86_64
  depends_on formula: [
    "vibepollo-app",
    "vibepollo-drm",
  ]

  installer script: {
    executable: "#{staged_path}/install.sh",
    args: [
      "#{HOMEBREW_PREFIX}/opt/vibepollo-drm",
      "#{staged_path}/vibeshine-drmctl",
    ],
    sudo: true,
  }

  uninstall script: {
    executable: "#{staged_path}/uninstall.sh",
    sudo: true,
  }

  caveats <<~EOS
    Before installing, copy your existing Secure Boot key pair to:

      /var/lib/vibepollo/drm/keys/mok.key
      /var/lib/vibepollo/drm/keys/MOK.der

    The private key must be unencrypted, root-owned, and mode 0600 (or 0400).
    The DER certificate must also be root-owned. The Cask never generates
    keys, imports certificates, or requests Secure Boot enrollment.

    The module is signed and installed for the currently running kernel, but
    it is not loaded and no service is enabled at boot. Load it only when
    needed with:

      sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl load

    Close virtual displays before unloading or uninstalling the module.
    Signing keys are preserved when the Cask is uninstalled.
  EOS
end
