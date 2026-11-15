#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf 'vibepollo Cask uninstaller: %s\n' "$*" >&2; }
fail() { printf 'vibepollo Cask uninstaller: error: %s\n' "$*" >&2; exit 1; }

# Homebrew runs Cask uninstall scripts without a TTY-aware sudo prompt.
# Authenticate explicitly on the controlling terminal, ignoring graphical
# askpass settings, then re-exec non-interactively with the cached ticket.
if [[ "$EUID" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || fail "sudo is required for privileged removal"
  [[ -r /dev/tty ]] || fail "no controlling terminal is available; run brew uninstall from a terminal"
  log "requesting administrator authentication in this terminal"
  if ! env -u SUDO_ASKPASS sudo -v -p 'Vibepollo Cask removal — password: ' </dev/tty; then
    fail "administrator authentication failed"
  fi
  exec env -u SUDO_ASKPASS sudo -n -- "$0" "$@"
fi

DRM_ROOT="/var/lib/vibepollo/drm"
STATE_DIR="$DRM_ROOT/state"
STATE_FILE="$STATE_DIR/vibeshine-drm-install"
MODULE_NAME="vibeshine_drm"

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
systemctl_bounded() {
  local limit="$1" description="$2" rc=0
  shift 2
  log "$description"
  timeout --foreground --kill-after=5s "${limit}s" systemctl "$@" || rc=$?
  if (( rc == 124 || rc == 137 )); then
    fail "timed out after ${limit}s while $description; no integration files were removed"
  elif (( rc != 0 )); then
    fail "command failed while $description (exit $rc); no integration files were removed"
  fi
}
unit_is_active() {
  local unit="$1" output rc=0
  output="$(timeout --foreground --kill-after=5s 10s systemctl is-active "$unit" 2>&1)" || rc=$?
  case "$rc:$output" in
    0:active|0:activating|0:reloading|0:deactivating) return 0 ;;
    3:inactive|3:failed|3:deactivating|4:unknown) return 1 ;;
    124:*|137:*) fail "systemd did not respond while checking $unit; no integration files were removed" ;;
    *) fail "could not safely determine the state of $unit (exit $rc): $output" ;;
  esac
}

[[ "$EUID" -eq 0 ]] || fail "this uninstaller must run with root privileges"
for command_name in stat awk sha256sum timeout; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
if [[ ! -e "$DRM_ROOT" && ! -L "$DRM_ROOT" ]]; then
  log "integration is already absent"
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

# Stop the optional pool before touching its helpers or the DRM module.
if command -v systemctl >/dev/null 2>&1; then
  if unit_is_active vibeshine-vkms.service; then
    systemctl_bounded 45 "stopping vibeshine-vkms.service" stop vibeshine-vkms.service
  fi
  if unit_is_active vibeshine-vkms-control.socket; then
    systemctl_bounded 20 "stopping vibeshine-vkms-control.socket" stop vibeshine-vkms-control.socket
  fi
fi

if [[ -d "/sys/module/$MODULE_NAME" ]]; then
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || fail "module is loaded but state is missing; refusing to unload an unverified module"
  [[ "$(stat -c '%u' "$STATE_FILE")" == 0 ]] || fail "installation state must be owned by root"
  state_mode="$(stat -c '%a' "$STATE_FILE")"
  (( (8#$state_mode & 0022) == 0 )) || fail "installation state must not be writable by group or others"
  [[ "$(state_value managed_load)" == "1" ]] ||
    fail "module is loaded but was not loaded by vibeshine-drmctl; refusing to unload an external module"
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
  module_refcount="$(cat "/sys/module/$MODULE_NAME/refcnt" 2>/dev/null || true)"
  if [[ "$module_refcount" =~ ^[0-9]+$ ]] && (( module_refcount > 0 )); then
    log "DRM module is held by the running desktop (refcount $module_refcount); leaving it loaded until reboot"
  else
    log "unloading the Cask-managed DRM module"
    rmmod_output=""
    rmmod_rc=0
    timeout --foreground --kill-after=5s 10s rmmod "$MODULE_NAME" > /dev/null 2> >(rmmod_output_file="$(mktemp)"; cat > "$rmmod_output_file"; printf '%s' "$rmmod_output_file" >&3) 3>&1 || rmmod_rc=$?
    if (( rmmod_rc != 0 )); then
      module_refcount="$(cat "/sys/module/$MODULE_NAME/refcnt" 2>/dev/null || true)"
      if { [[ "$module_refcount" =~ ^[0-9]+$ ]] && (( module_refcount > 0 )); }; then
        log "DRM module became busy (refcount $module_refcount); leaving it loaded until reboot"
      elif (( rmmod_rc == 124 || rmmod_rc == 137 )); then
        fail "rmmod did not finish within 10s; the module and integration files were left in place"
      else
        fail "could not unload the managed module (exit $rmmod_rc); the integration files were left in place"
      fi
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
if command -v systemctl >/dev/null 2>&1; then
  systemctl_bounded 30 "reloading systemd after unit removal" daemon-reload
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
log "removed Vibeshine DRM integration files"
log "preserved signing keys in $DRM_ROOT/keys"
