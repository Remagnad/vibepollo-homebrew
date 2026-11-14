# Vibepollo Homebrew tap

Homebrew formulae for Linux x86_64.

The application Formula builds the Linux x86_64 app with CUDA 12.9.1 enabled, matching Vibepollo upstream release policy and retaining Pascal (`sm_61`) device code. The CUDA Toolkit is a build-only dependency; the installed system must provide a compatible NVIDIA driver to use NVIDIA acceleration. The Formula installs the native C++ AppIndicator tray and runtime assets, but deliberately does **not** install machine-wide systemd services, udev/sysusers rules, privileged helpers or kernel modules. Those privileged integrations and the complete install/uninstall lifecycle are reserved for the Cask.

## Install

```bash
brew tap Remagnad/vibepollo-homebrew https://github.com/Remagnad/vibepollo-homebrew
brew install Remagnad/vibepollo-homebrew/vibepollo-app
```

The tap checks [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) every 15 minutes. A new stable release is built on GitHub Actions with the pinned LizardByte CUDA Toolkit 12.9 formula and GCC 14. The build verifies that the resulting executable contains Pascal `sm_61` device code. A release only becomes active after source-build checks, bottle creation, a clean bottle installation test and Homebrew audits succeed. Failed builds leave the last working Formula untouched.

To install a published update, run `brew upgrade Remagnad/vibepollo-homebrew/vibepollo-app`. Homebrew does not automatically upgrade installed packages just because the tap has changed.

The Linux bottle targets x86_64 and is built on Ubuntu 22.04. Building from source also requires the distribution's `libudev-dev` package; it is not a Homebrew formula dependency.
