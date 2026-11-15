# Vibepollo Homebrew tap

Homebrew formulae for Linux x86_64.

The application Formula builds the Linux x86_64 app with CUDA 12.9.1 enabled, matching Vibepollo upstream release policy and retaining Pascal (`sm_61`) device code. The CUDA Toolkit is used only during source builds; it is deliberately not a Homebrew dependency of the published bottle, so bottle users do not need to add the LizardByte tap. The installed system must provide a compatible NVIDIA driver to use NVIDIA acceleration. The Formula installs the native C++ AppIndicator tray and runtime assets, but deliberately does **not** install machine-wide systemd services, udev/sysusers rules, privileged helpers or kernel modules. Those privileged integrations and the complete install/uninstall lifecycle are reserved for the Cask.

## Install

```bash
brew tap Remagnad/vibepollo-homebrew https://github.com/Remagnad/vibepollo-homebrew
brew install Remagnad/vibepollo-homebrew/vibepollo-app
```

The tap checks [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) every 15 minutes. A new stable release is built on GitHub Actions with the pinned LizardByte CUDA Toolkit 12.9 formula and GCC 14. The build verifies that the resulting executable contains Pascal `sm_61` device code. A release only becomes active after source-build checks, bottle creation, a clean bottle installation test and Homebrew audits succeed. Failed builds leave the last working Formula untouched.

To install a published update, run `brew upgrade Remagnad/vibepollo-homebrew/vibepollo-app`. Homebrew does not automatically upgrade installed packages just because the tap has changed.

The Linux bottle targets x86_64 and is built on Ubuntu 22.04. The published bottle can be installed without the LizardByte tap. Building from source requires the distribution's `libudev-dev` package and the pinned CUDA toolchain:

```bash
brew tap LizardByte/homebrew
brew trust --formula lizardbyte/homebrew/cuda@12.9
brew install lizardbyte/homebrew/cuda@12.9
```


## Vibeshine DRM kernel module

The vibepollo-drm Formula builds the pinned libvirtualdisplay vibeshine_drm.ko
source against the headers for the currently running Linux kernel. It does not
sign, install, load, or enable the module. Linux 6.16 or newer and matching
kernel development files are required. Rebuild the Formula after changing
kernels; automatic DKMS integration is not included yet.

The vibepollo Cask depends on vibepollo-app and vibepollo-drm. Its privileged
installer signs the Formula artifact with the key pair that the user places in
this fixed directory:

- /var/lib/vibepollo/drm/keys/mok.key — private key, root-owned, mode 0600 (or 0400).
- /var/lib/vibepollo/drm/keys/MOK.der — DER certificate, root-owned.

The Cask does not generate keys, enroll certificates, or overwrite the
original key files. It installs the signed module and a small on-demand
controller under /var/lib/vibepollo/drm. It does not load the module, enable
a boot service, or start Vibepollo automatically.

Example key setup (replace the source private-key filename if yours differs):

    sudo install -d -o root -g root -m 0700 /var/lib/vibepollo/drm/keys
    sudo install -o root -g root -m 0600 ~/Projects/Vibepollo/keys/MOK.priv /var/lib/vibepollo/drm/keys/mok.key
    sudo install -o root -g root -m 0644 ~/Projects/Vibepollo/keys/MOK.der /var/lib/vibepollo/drm/keys/MOK.der

Install the DRM Formula from source before installing the Cask:

    brew install --build-from-source Remagnad/vibepollo-homebrew/vibepollo-drm
    brew install --cask Remagnad/vibepollo-homebrew/vibepollo

Load, inspect, or unload the module manually:

    sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl load
    sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl status
    sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl unload

The Cask uninstall removes its installed module and controller but preserves
/var/lib/vibepollo/drm/keys. A loaded module must be unloaded before the
Cask can be removed. Kernel-version changes require rebuilding and reinstalling
the Formula and Cask until DKMS support is implemented.

Static checks can be run with:

    python3 scripts/test-drm-packages.py
