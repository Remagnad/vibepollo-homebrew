# Vibepollo Homebrew tap

Homebrew formulae for Linux x86_64.

The initial package is `vibepollo-app`: the application, runtime assets, Linux capture backends, native AppIndicator tray and unprivileged Python `vibepollo-tray` companion. The companion and its desktop launcher stay inside the Cellar; login autostart is reserved for the Cask. The Formula deliberately does **not** install machine-wide systemd services, udev/sysusers rules, privileged helpers or kernel modules. Those integrations are reserved for a separate Cask/DRM phase.

## Install

```bash
brew tap Remagnad/vibepollo-homebrew https://github.com/Remagnad/vibepollo-homebrew
brew install Remagnad/vibepollo-homebrew/vibepollo-app
```

The tap checks [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo) every 15 minutes. A new stable release is built on GitHub Actions and only becomes the active formula after source-build checks, bottle creation, a clean bottle installation test and Homebrew audits succeed. Failed builds leave the last working Formula untouched.

To install a published update, run `brew upgrade Remagnad/vibepollo-homebrew/vibepollo-app`. Homebrew does not automatically upgrade installed packages just because the tap has changed.

The Linux bottle targets x86_64 and is built on Ubuntu 22.04. Building from source also requires the distribution's `libudev-dev` package; it is not a Homebrew formula dependency.
