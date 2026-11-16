#!/usr/bin/env bash
set -Eeuo pipefail

STATE_FILE="/var/lib/vibepollo/drm/state/vibeshine-drm-install"

[[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || {
  printf 'vibepollo Cask installer: error: privileged installation did not create its state file.\\n' >&2
  exit 1
}
[[ "$(stat -c '%u' "$STATE_FILE")" == 0 ]] || {
  printf 'vibepollo Cask installer: error: installation state is not root-owned.\\n' >&2
  exit 1
}

printf 'Vibepollo Cask: privileged integration installation completed.\\n'
