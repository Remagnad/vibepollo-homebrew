#!/usr/bin/env bash
set -Eeuo pipefail

# The privileged cleanup already ran in uninstall_preflight_steps through
# Homebrew's sudo runner. This stanza satisfies Homebrew's requirement that
# Casks with an installer declare an uninstall artifact.
printf 'Vibepollo Cask: privileged integration cleanup completed.\n'
