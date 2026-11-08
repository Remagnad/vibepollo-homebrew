# Vibepollo Homebrew tap

Homebrew formulae for Linux x86_64.

The initial package is `vibepollo-app`: the application, its runtime assets and the Linux capture backends. It deliberately does **not** install machine-wide systemd services, udev/sysusers rules, privileged helpers or kernel modules. Those integrations are reserved for a separate Cask/DRM phase.

## Install

```bash
brew tap Remagnad/vibepollo-homebrew https://github.com/Remagnad/vibepollo-homebrew
brew install Remagnad/vibepollo-homebrew/vibepollo-app
```

The tap monitors stable releases from [Nonary/Vibepollo](https://github.com/Nonary/Vibepollo). A new release is built on GitHub Actions and only becomes the active formula after the source build, bottle checks and a clean bottle installation test succeed.

The Linux bottle is built for x86_64 on Ubuntu 22.04. Building from source requires the dependencies declared in the formula.
