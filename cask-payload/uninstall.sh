#!/usr/bin/env bash
set -Eeuo pipefail

# Use terminal sudo instead of Homebrew's graphical sudo -A/askpass path.
if [[ "$EUID" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    printf 'vibepollo Cask uninstaller: error: sudo is required for privileged removal.\n' >&2
    exit 1
  }
  exec sudo -- "$0" "$@"
fi
DRM_ROOT="/var/lib/vibepollo/drm"
STATE_DIR="$DRM_ROOT/state"
STATE_FILE="$STATE_DIR/vibeshine-drm-install"
MODULE_NAME="vibeshine_drm"
fail() { printf 'vibepollo Cask uninstaller: error: %s\n' "$*" >&2; exit 1; }
require_root_directory() {
  local path="$1" mode
  [[ -d "$path" && ! -L "$path" ]] || fail "refusing unsafe directory path: $path"
  [[ "$(stat -c '%u' "$path")" == 0 ]] || fail "$path must be owned by root"
  mode="$(stat -c '%a' "$path")"
  (( (8#$mode & 0022) == 0 )) || fail "$path must not be writable by group or others"
}
state_value() {
  local key="$1"
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE"
}
[[ "$EUID" -eq 0 ]] || fail "this uninstaller must run with root privileges"
command -v stat >/dev/null 2>&1 || fail "GNU stat from coreutils is required"
command -v awk >/dev/null 2>&1 || fail "awk is required"
if [[ ! -e "$DRM_ROOT" && ! -L "$DRM_ROOT" ]]; then
  printf 'Vibeshine DRM integration is already absent.\n'
  exit 0
fi
for parent in /var /var/lib /var/lib/vibepollo "$DRM_ROOT"; do require_root_directory "$parent"; done
if [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then require_root_directory "$STATE_DIR"; fi
if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail "refusing unsafe installation state file"
  [[ "$(stat -c '%u' "$STATE_FILE")" == 0 ]] || fail "installation state must be owned by root"
  state_mode="$(stat -c '%a' "$STATE_FILE")"
  (( (8#$state_mode & 0022) == 0 )) || fail "installation state must not be writable by group or others"
fi
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

# Stop the optional pool before touching its helpers or the DRM module.
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet vibeshine-vkms.service; then
    systemctl stop vibeshine-vkms.service || fail "could not stop vibeshine-vkms.service; close active virtual displays and retry"
  fi
  if systemctl is-active --quiet vibeshine-vkms-control.socket; then
    systemctl stop vibeshine-vkms-control.socket || fail "could not stop the Vibeshine control socket"
  fi
fi

if [[ -d "/sys/module/$MODULE_NAME" ]]; then
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail "module is loaded but state is missing; refusing to unload an unverified module"
  [[ "$(stat -c '%u' "$STATE_FILE")" == 0 ]] || fail "installation state must be owned by root"
  state_mode="$(stat -c '%a' "$STATE_FILE")"
  (( (8#$state_mode & 0022) == 0 )) || fail "installation state must not be writable by group or others"
  [[ "$(state_value managed_load)" == "1" ]] ||
    fail "module is loaded but was not loaded by vibeshine-drmctl; unload it manually and retry"
  expected_version="$(state_value module_version)"
  loaded_version="$(cat "/sys/module/$MODULE_NAME/version" 2>/dev/null || true)"
  [[ -n "$expected_version" && "$loaded_version" == "$expected_version" ]] ||
    fail "loaded module is not the exact source-qualified build managed by this Cask"
  expected_srcversion="$(state_value module_srcversion)"
  loaded_srcversion="$(cat "/sys/module/$MODULE_NAME/srcversion" 2>/dev/null || true)"
  if [[ -n "$expected_srcversion" && -n "$loaded_srcversion" && "$expected_srcversion" != "$loaded_srcversion" ]]; then
    fail "loaded module source identity does not match this Cask"
  fi
  expected_token="$(state_value load_token)"
  loaded_token="$(cat "/sys/module/$MODULE_NAME/parameters/vibeshine_drmctl_token" 2>/dev/null || true)"
  [[ "$expected_token" =~ ^[0-9a-f]{64}$ && "$loaded_token" == "$expected_token" ]] ||
    fail "the loaded module does not carry this Cask helper's load token; refusing to unload an external module"
  command -v rmmod >/dev/null 2>&1 || fail "rmmod from kmod is required"
  # A compositor may keep DRM file descriptors open after the configfs pool
  # has been stopped. In that case the kernel correctly pins the module.
  # Do not force-unload it or abort the Cask removal: unlinking the installed
  # module file is safe, and the in-memory module will disappear at reboot.
  # Only defer when the kernel reports a positive reference count; any other
  # rmmod failure remains fatal.
  rmmod_output=""
  if ! rmmod_output="$(rmmod "$MODULE_NAME" 2>&1)"; then
    module_refcount="$(cat "/sys/module/$MODULE_NAME/refcnt" 2>/dev/null || true)"
    if [[ "$module_refcount" =~ ^[0-9]+$ ]] && (( module_refcount > 0 )); then
      printf 'Vibeshine DRM module is still referenced by the running desktop (refcount %s). Leaving it loaded until reboot; removing the Cask files safely.\\n' "$module_refcount"
    else
      fail "could not unload the managed module: $rmmod_output"
    fi
  fi
fi

UNIT_DIR="/etc/systemd/system"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  unit_path="$UNIT_DIR/$unit"
  [[ -e "$unit_path" || -L "$unit_path" ]] || continue
  [[ -f "$unit_path" && ! -L "$unit_path" ]] || fail "refusing unsafe systemd unit path: $unit_path"
  expected_unit_sha="$(state_value "unit_${unit}_sha256")"
  [[ "$expected_unit_sha" =~ ^[0-9a-f]{64}$ ]] || fail "no ownership record for $unit; leaving it untouched"
  actual_unit_sha="$(sha256sum "$unit_path" | awk '{print $1}')"
  [[ "$actual_unit_sha" == "$expected_unit_sha" ]] || fail "$unit was modified outside this Cask; leaving it untouched"
  rm -f -- "$unit_path"
done
if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi


MODULES_DIR="$DRM_ROOT/modules"
if [[ -e "$MODULES_DIR" || -L "$MODULES_DIR" ]]; then
  require_root_directory "$MODULES_DIR"
  for kernel_dir in "$MODULES_DIR"/*; do
    [[ -e "$kernel_dir" || -L "$kernel_dir" ]] || continue
    require_root_directory "$kernel_dir"
    kernel_release="$(basename "$kernel_dir")"
    [[ "$kernel_release" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "refusing invalid kernel directory: $kernel_release"
    module_file="$kernel_dir/vibeshine_drm.ko"
    if [[ -e "$module_file" || -L "$module_file" ]]; then
      [[ -f "$module_file" && ! -L "$module_file" ]] || fail "refusing unexpected module path: $module_file"
      [[ "$(stat -c '%u' "$module_file")" == 0 ]] || fail "$module_file must be owned by root"
      rm -f -- "$module_file"
    fi
    rmdir "$kernel_dir" 2>/dev/null || true
  done
  rmdir "$MODULES_DIR" 2>/dev/null || true
fi
for directory in bin state; do
  path="$DRM_ROOT/$directory"
  [[ -e "$path" || -L "$path" ]] || continue
  require_root_directory "$path"
  case "$directory" in
    bin)
for helper_name in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
        helper="$path/$helper_name"
        [[ -e "$helper" || -L "$helper" ]] || continue
        [[ -f "$helper" && ! -L "$helper" ]] || fail "refusing unsafe helper path: $helper"
        expected_helper_sha="$(state_value "helper_${helper_name}_sha256")"
        if [[ ! "$expected_helper_sha" =~ ^[0-9a-f]{64}$ ]]; then
          [[ "$helper_name" == "vibeshine-drmctl" && "$(state_value format)" == "1" ]] || fail "no ownership record for $helper_name; leaving it untouched"
        else
          actual_helper_sha="$(sha256sum "$helper" | awk '{print $1}')"
          [[ "$actual_helper_sha" == "$expected_helper_sha" ]] || fail "$helper_name was modified outside this Cask; leaving it untouched"
        fi
        rm -f -- "$helper"
      done
      ;;
    state)
      [[ ! -L "$STATE_FILE" ]] || fail "refusing symbolic-link state file"
      rm -f -- "$STATE_FILE"
      ;;
  esac
  rmdir "$path" 2>/dev/null || true
done
printf 'Removed Vibeshine DRM integration files.\n'
printf 'Preserved signing keys in %s/keys.\n' "$DRM_ROOT"
