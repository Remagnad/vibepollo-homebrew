#!/usr/bin/env bash
set -Eeuo pipefail
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
  rmmod "$MODULE_NAME" || fail "module is busy; close virtual displays, unload it, then retry"
fi

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
      helper="$path/vibeshine-drmctl"
      [[ ! -L "$helper" ]] || fail "refusing symbolic-link controller"
      rm -f -- "$helper"
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
