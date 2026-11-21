# Vibepollo Homebrew tap

Homebrew formulae for Linux x86_64.

The application Formula builds the Linux x86_64 app with CUDA 12.9.1 enabled, matching Vibepollo upstream release policy and retaining Pascal (\`sm_61\`) device code. The CUDA Toolkit is used only during source builds; it is deliberately not a Homebrew dependency of the published bottle, so bottle users do not need to add the LizardByte tap. The installed system must provide a compatible NVIDIA driver to use NVIDIA acceleration. The Formula installs the native C++ AppIndicator tray and runtime assets, but deliberately does **not** install machine-wide systemd services, udev/sysusers rules, privileged helpers or kernel modules. Those privileged integrations and the complete install/uninstall lifecycle are reserved for the Cask.

## Install

\`\`\`bash
brew tap Remagnad/vibepollo-homebrew https://github.com/Remagnad/vibepollo-homebrew
brew install Remagnad/vibepollo-homebrew/vibepollo-app
\`\`\`

The tap checks [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) every 15 minutes. A new stable release is built on GitHub Actions with the pinned LizardByte CUDA Toolkit 12.9 formula and GCC 14. The build verifies that the resulting executable contains Pascal \`sm_61\` device code. A release only becomes active after source-build checks, bottle creation, a clean bottle installation test and Homebrew audits succeed. Failed builds leave the last working Formula untouched.

To install a published update, run \`brew upgrade Remagnad/vibepollo-homebrew/vibepollo-app\`. Homebrew does not automatically upgrade installed packages just because the tap has changed.

The Linux bottle targets x86_64 and is built on Ubuntu 22.04. The published bottle can be installed without the LizardByte tap. Building from source requires the distribution's \`libudev-dev\` package and the pinned CUDA toolchain:

\`\`\`bash
brew tap LizardByte/homebrew
brew trust --formula lizardbyte/homebrew/cuda@12.9
brew install lizardbyte/homebrew/cuda@12.9
\`\`\`

## Vibeshine DRM kernel module

The \`vibepollo-drm\` Formula builds the pinned libvirtualdisplay \`vibeshine_drm.ko\` source against headers for the currently running Linux kernel. It does not sign, install, load or enable the module. Linux 6.16 or newer and matching kernel development files are required. Rebuild the Formula after changing kernels; automatic DKMS integration is not included yet. The embedded module version includes the pinned libvirtualdisplay commit so modules from different source revisions cannot be confused just because their Vibepollo release number matches.

The \`vibepollo\` Cask depends on \`vibepollo-app\` and \`vibepollo-drm\`. Its privileged installer signs the Formula artifact using your existing key pair, placed at:

- \`/var/lib/vibepollo/drm/keys/mok.key\` — unencrypted private key, root-owned, mode \`0600\` (or \`0400\`).
- \`/var/lib/vibepollo/drm/keys/MOK.der\` — DER certificate, root-owned.

The key directory itself must be root-owned and mode \`0700\`. The Cask verifies that the private key and certificate match. It never generates or replaces the keys, imports certificates, or requests Secure Boot enrollment.

Example key setup (replace the source private-key filename if yours differs):

\`\`\`bash
sudo install -d -o root -g root -m 0700 /var/lib/vibepollo/drm/keys
sudo install -o root -g root -m 0600 ~/Projects/Vibepollo/keys/MOK.priv /var/lib/vibepollo/drm/keys/mok.key
sudo install -o root -g root -m 0644 ~/Projects/Vibepollo/keys/MOK.der /var/lib/vibepollo/drm/keys/MOK.der
\`\`\`

Existing installs created by the older graphical-askpass Cask need a one-time receipt migration. After \`brew update\`, run this as your normal desktop user (not through \`sudo\`):

\`\`\`bash
python3 "$(brew --repo Remagnad/vibepollo-homebrew)/scripts/migrate-installed-cask-sudo.py"
\`\`\`

The migration verifies the published Cask archive against the current tap SHA-256, replaces the installed uninstaller, removes only the obsolete \`sudo: true\` flag from Homebrew's installed uninstall receipt, backs up that receipt, and then completes the normal Cask uninstall. Fresh installations do not need this migration.

Install the DRM Formula from source before installing the Cask:

\`\`\`bash
brew install --build-from-source Remagnad/vibepollo-homebrew/vibepollo-drm
brew install --cask Remagnad/vibepollo-homebrew/vibepollo
\`\`\`

Load, inspect, or unload the module manually:

\`\`\`bash
sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl load
sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl status
sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl unload
\`\`\`

The Cask does not load the module or enable services during installation. When you launch Vibepollo from the Homebrew launcher, it requests graphical authorization through \`/usr/bin/pkexec\` and starts the managed virtual-display pool if it is not already active. The graphical lifecycle controls require a PolicyKit installation that provides \`/usr/bin/pkexec\`. Without it, the app remains installed, but on-demand privileged actions and the tray lifecycle controls are unavailable; you can start the pool manually with \`sudo systemctl start vibeshine-vkms.service\`. The tray menu provides:

- **Quit** — exits Vibepollo and leaves the system integration running.
- **Quit and stop services** — exits gracefully, stops the virtual-display pool, then attempts to unload only the verified Cask-managed module. If the compositor still holds the module, it is left loaded.
- **Start with system** — an opt-in checkbox, disabled on first installation. When enabled, the VKMS pool starts during boot and Vibepollo launches with the graphical session. Turning it off affects the next boot/login but does not stop the current session.

The controller records when it loads the module. On Cask uninstall, only a matching module loaded through that controller is unloaded automatically. If the module was loaded manually or by another package, the uninstaller refuses to unload it. The Cask removes its module, helpers, services and owned autostart state but preserves \`/var/lib/vibepollo/drm/keys\`. Kernel-version changes require rebuilding and reinstalling the Formula and Cask until DKMS support is implemented.

Static checks can be run with:

\`\`\`bash
python3 scripts/test-drm-packages.py
\`\`\`
