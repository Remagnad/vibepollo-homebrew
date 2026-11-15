#!/usr/bin/env bash
set -Eeuo pipefail

DRM_ROOT="/var/lib/vibepollo/drm"
MODULE_NAME="vibeshine_drm"

fail() {
  printf 'vibepollo Cask uninstaller: error: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || fail "this uninstaller must run with root privileges"

if [[ -d "/sys/module/$MODULE_NAME" ]]; then
  command -v rmmod >/dev/null 2>&1 || fail "rmmod from kmod is required to remove the loaded module"
  rmmod "$MODULE_NAME" ||
    fail "the module is busy; close Vibepollo virtual displays, unload the module, then retry"
fi

MODULES_DIR="$DRM_ROOT/modules"
if [[ -e "$MODULES_DIR" ]]; then
  [[ -d "$MODULES_DIR" && ! -L "$MODULES_DIR" ]] ||
    fail "refusing to remove an unexpected modules path"
  for kernel_dir in "$MODULES_DIR"/*; do
    [[ -e "$kernel_dir" ]] || continue
    [[ -d "$kernel_dir" && ! -L "$kernel_dir" ]] ||
      fail "refusing to traverse an unexpected path: $kernel_dir"
    kernel_release="$(basename "$kernel_dir")"
    [[ "$kernel_release" =~ ^[A-Za-z0-9._+-]+$ ]] ||
      fail "refusing an invalid kernel directory name: $kernel_release"
    module_file="$kernel_dir/vibeshine_drm.ko"
    [[ ! -L "$module_file" ]] || fail "refusing to remove a symbolic-link module: $module_file"
    rm -f -- "$module_file"
    rmdir "$kernel_dir" 2>/dev/null || true
  done
  rmdir "$MODULES_DIR" 2>/dev/null || true
fi

[[ ! -L "$DRM_ROOT/bin" ]] || fail "refusing to traverse a symbolic-link bin directory"
rm -f -- "$DRM_ROOT/bin/vibeshine-drmctl"
rmdir "$DRM_ROOT/bin" 2>/dev/null || true

[[ ! -L "$DRM_ROOT/state" ]] || fail "refusing to traverse a symbolic-link state directory"
rm -f -- "$DRM_ROOT/state/vibeshine-drm-install"
rmdir "$DRM_ROOT/state" 2>/dev/null || true

printf 'Removed Vibeshine DRM integration files.\n'
printf 'Preserved signing keys in %s/keys.\n' "$DRM_ROOT"
