#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$EUID" -ne 0 ]] || {
  printf 'Vibepollo module updater must run as the desktop user, not root.\n' >&2
  exit 1
}

script_path="$(readlink -f -- "$0")" || {
  printf 'Vibepollo module updater: cannot resolve its installation path\n' >&2
  exit 1
}
case "$script_path" in
  */Cellar/vibepollo-app/*/libexec/vibepollo-module-update) ;;
  *)
    printf 'Vibepollo module updater: unexpected Homebrew path: %s\n' "$script_path" >&2
    exit 1
    ;;
esac
app_prefix="${script_path%/libexec/vibepollo-module-update}"
brew_prefix="${app_prefix%%/Cellar/*}"
[[ "$brew_prefix" != "$app_prefix" && -x "$brew_prefix/bin/brew" ]] || {
  printf 'Vibepollo module updater: could not locate Homebrew\n' >&2
  exit 1
}

BREW="$brew_prefix/bin/brew"
DRM_PREFIX="$brew_prefix/opt/vibepollo-drm"
LIFECYCLE_HELPER="/var/lib/vibepollo/drm/bin/vibepollo-lifecycle"
FORMULA_TOKEN="Remagnad/vibepollo-homebrew/vibepollo-drm"
NOTIFY="$brew_prefix/bin/notify-send"
if [[ ! -x "$NOTIFY" ]]; then
  NOTIFY="$(command -v notify-send 2>/dev/null || true)"
fi

state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
log_dir="$state_home/vibepollo"
mkdir -p -- "$log_dir"
chmod 0700 "$log_dir"
log_file="$log_dir/kernel-module-update.log"
exec 9>"$log_file.lock"
if ! flock -n 9; then
  printf 'Vibepollo module updater: an update is already running\n' >&2
  exit 0
fi

notify() {
  local title="$1" message="$2"
  if [[ -n "$NOTIFY" && -x "$NOTIFY" ]]; then
    "$NOTIFY" --app-name="Vibepollo" --urgency=normal --expire-time=12000 \
      "$title" "$message" >/dev/null 2>&1 || true
  fi
}

fail() {
  local message="$1"
  printf '[%s] ERROR: %s\n' "$(date --iso-8601=seconds)" "$message" | tee -a "$log_file" >&2
  notify "Vibepollo kernel-module update failed" "$message. Details: $log_file"
  exit 1
}

current_kernel="$(uname -r)"
[[ -n "$current_kernel" ]] || fail "could not determine the running kernel"
{
  printf '\n[%s] Starting kernel-module update for %s\n' "$(date --iso-8601=seconds)" "$current_kernel"
  printf 'Homebrew prefix: %s\n' "$brew_prefix"
} >> "$log_file"

[[ -x "$LIFECYCLE_HELPER" && ! -L "$LIFECYCLE_HELPER" ]] ||
  fail "the privileged Vibepollo integration is missing; reinstall the Vibepollo Cask"
[[ "$(stat -c '%u' "$LIFECYCLE_HELPER")" == 0 ]] ||
  fail "the privileged lifecycle helper is not root-owned"
[[ -x /usr/bin/pkexec ]] || fail "/usr/bin/pkexec is unavailable"

formula_is_ready() {
  local prefix="$1" kernel version commit module name vermagic module_version
  [[ -d "$prefix" && ! -L "$prefix" ]] || return 1
  for metadata in kernel-release module-version libvirtualdisplay-commit; do
    [[ -f "$prefix/libexec/$metadata" && ! -L "$prefix/libexec/$metadata" ]] || return 1
  done
  kernel="$(tr -d '[:space:]' < "$prefix/libexec/kernel-release")"
  version="$(tr -d '[:space:]' < "$prefix/libexec/module-version")"
  commit="$(tr -d '[:space:]' < "$prefix/libexec/libvirtualdisplay-commit")"
  module="$prefix/libexec/vibeshine_drm.ko"
  [[ "$kernel" == "$current_kernel" && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9a-f]{12}$ ]] || return 1
  [[ "$commit" =~ ^[0-9a-f]{40}$ && -f "$module" && ! -L "$module" ]] || return 1
  name="$(modinfo -F name "$module" 2>/dev/null || true)"
  module_version="$(modinfo -F version "$module" 2>/dev/null || true)"
  vermagic="$(modinfo -F vermagic "$module" 2>/dev/null | awk '{print $1}')"
  [[ "$name" == vibeshine_drm && "$module_version" == "$version" && "$vermagic" == "$current_kernel" ]]
}

if ! formula_is_ready "$DRM_PREFIX"; then
  notify "Vibepollo is rebuilding its kernel module" \
    "Compiling vibeshine_drm.ko for kernel $current_kernel. This may take a few minutes."
  printf '[%s] Rebuilding %s from source\n' "$(date --iso-8601=seconds)" "$FORMULA_TOKEN" >> "$log_file"
  if ! HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" reinstall --build-from-source "$FORMULA_TOKEN" >> "$log_file" 2>&1; then
    fail "Homebrew could not build the module for kernel $current_kernel. Check that matching kernel development files and GNU make are installed"
  fi
fi

formula_is_ready "$DRM_PREFIX" ||
  fail "the DRM Formula did not produce a valid module for kernel $current_kernel"

notify "Vibepollo is installing the updated kernel module" \
  "Requesting authorization to sign and install the module for kernel $current_kernel."
printf '[%s] Requesting PolicyKit authorization for module installation\n' "$(date --iso-8601=seconds)" >> "$log_file"
if ! /usr/bin/pkexec "$LIFECYCLE_HELPER" update-module >> "$log_file" 2>&1; then
  fail "the privileged installation was cancelled or failed; check the update log before retrying"
fi

printf '[%s] Kernel-module update completed for %s\n' "$(date --iso-8601=seconds)" "$current_kernel" >> "$log_file"
notify "Vibepollo kernel module updated" \
  "The signed module is installed for kernel $current_kernel and the virtual-display pool has been started."
exit 0
