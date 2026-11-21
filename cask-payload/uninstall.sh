#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf 'vibepollo Cask uninstaller: %s\n' "$*" >&2; }
fail() { printf 'vibepollo Cask uninstaller: error: %s\n' "$*" >&2; exit 1; }

DRM_ROOT="/var/lib/vibepollo/drm"
STATE_DIR="$DRM_ROOT/state"
STATE_FILE="$STATE_DIR/vibeshine-drm-install"
BIN_DIR="$DRM_ROOT/bin"
SELINUX_FCONTEXT_SPEC="$BIN_DIR/(vibeshine-drmctl|vibeshine-vkms|vibeshine-vkms-quiesce|vibeshine-vkms-peercred|vibepollo-lifecycle|vibepollo-user-launch)"
SELINUX_RULE_OWNED=0
MODULE_NAME="vibeshine_drm"
STATE_TRUSTED=0
MODULE_UNVERIFIED_LOADED=0

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
remove_owned_selinux_fcontext() {
  [[ "$SELINUX_RULE_OWNED" == "1" ]] || return 0
  for helper_name in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
    helper="$BIN_DIR/$helper_name"
    [[ ! -e "$helper" && ! -L "$helper" ]] || fail "cannot remove the Cask-owned SELinux rule while helper remains: $helper"
  done
  command -v semanage >/dev/null 2>&1 || fail "semanage is required to remove the Cask-owned SELinux file-context rule"
  existing_context="$(semanage fcontext -l -C | awk -v spec="$SELINUX_FCONTEXT_SPEC" '$1 == spec { print $NF; exit }')"
  if [[ -n "$existing_context" ]]; then
    IFS=: read -r _ _ existing_type _ <<< "$existing_context"
    [[ "$existing_type" == "bin_t" ]] || fail "the SELinux rule for Vibeshine helpers was changed outside this Cask; preserving it"
    semanage fcontext -d -f f "$SELINUX_FCONTEXT_SPEC" || fail "could not remove the Cask-owned SELinux file-context rule"
    log "removed the Cask-owned SELinux executable-label rule"
  else
    log "the Cask-owned SELinux executable-label rule is already absent"
  fi
  SELINUX_RULE_OWNED=0
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
    3:inactive|3:failed|3:deactivating|4:inactive|4:unknown) return 1 ;;
    124:*|137:*) fail "systemd did not respond while checking $unit; no integration files were removed" ;;
    *) fail "could not safely determine the state of $unit (exit $rc): $output" ;;
  esac
}

[[ "$EUID" -eq 0 ]] || fail "Homebrew must run this uninstaller with sudo: true"
log "starting privileged uninstall"
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
  STATE_TRUSTED=1
  SELINUX_RULE_OWNED="$(state_value selinux_fcontext_owned)"
  [[ "$SELINUX_RULE_OWNED" == "1" ]] || SELINUX_RULE_OWNED=0
fi

# Remove only the XDG autostart entry whose checksum and owner are recorded
# by this Cask. If it was edited or replaced, the lifecycle helper aborts and
# the uninstaller preserves the user's file rather than deleting it.
if [[ "$STATE_TRUSTED" == "1" && -x "$BIN_DIR/vibepollo-lifecycle" &&
      -f "$STATE_DIR/vibepollo-lifecycle" && ! -L "$STATE_DIR/vibepollo-lifecycle" ]]; then
  lifecycle_mode="$(stat -c '%a' "$STATE_DIR/vibepollo-lifecycle")"
  (( (8#$lifecycle_mode & 0022) == 0 )) || fail "lifecycle state is writable by group or others"
  lifecycle_uid="$(awk -F= '$1 == "desktop_uid" {print $2; exit}' "$STATE_DIR/vibepollo-lifecycle")"
  lifecycle_app_prefix="$(awk -F= '$1 == "app_prefix" {sub(/^[^=]*=/, ""); print; exit}' "$STATE_DIR/vibepollo-lifecycle")"
  [[ "$lifecycle_uid" =~ ^[1-9][0-9]*$ && "$lifecycle_app_prefix" == /* ]] ||
    fail "lifecycle state is invalid; preserving autostart and integration files"
  lifecycle_expected="$(state_value helper_vibepollo-lifecycle_sha256)"
  lifecycle_actual="$(sha256sum "$BIN_DIR/vibepollo-lifecycle" | awk '{print $1}')"
  [[ "$lifecycle_expected" =~ ^[0-9a-f]{64}$ && "$lifecycle_actual" == "$lifecycle_expected" ]] ||
    fail "lifecycle helper ownership could not be verified; preserving autostart and integration files"
  "$BIN_DIR/vibepollo-lifecycle" remove-autostart ||
    fail "could not safely remove the Cask-owned autostart configuration"
fi

# Stop the optional pool before touching its helpers or the DRM module.
log "checking and stopping optional Vibeshine services"
if command -v systemctl >/dev/null 2>&1; then
  if unit_is_active vibeshine-vkms.service; then
    systemctl_bounded 45 "stopping vibeshine-vkms.service" stop vibeshine-vkms.service
  fi
  if unit_is_active vibeshine-vkms-control.socket; then
    systemctl_bounded 20 "stopping vibeshine-vkms-control.socket" stop vibeshine-vkms-control.socket
  fi
fi

log "checking loaded DRM module"
if [[ -d "/sys/module/$MODULE_NAME" ]]; then
  if [[ "$STATE_TRUSTED" != "1" ]]; then
    log "module is loaded but the Cask state is missing; refusing to unload it and leaving it loaded until reboot"
    MODULE_UNVERIFIED_LOADED=1
  elif [[ "$(state_value managed_load)" != "1" ]]; then
    log "module is not recorded as loaded by vibeshine-drmctl; leaving the externally loaded module untouched"
  else
    expected_version="$(state_value module_version)"
    loaded_version="$(cat "/sys/module/$MODULE_NAME/version" 2>/dev/null || true)"
    [[ -n "$expected_version" && "$loaded_version" == "$expected_version" ]] ||
      fail "loaded module is not the exact source-qualified build recorded by this Cask"
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
      log "DRM module is held by the running desktop (refcount $module_refcount); uninstall cannot safely continue"
    else
      log "unloading the Cask-managed DRM module"
      rmmod_output=""
      rmmod_rc=0
      rmmod_output="$(timeout --foreground --kill-after=5s 10s rmmod "$MODULE_NAME" 2>&1)" || rmmod_rc=$?
      if (( rmmod_rc != 0 )); then
        module_refcount="$(cat "/sys/module/$MODULE_NAME/refcnt" 2>/dev/null || true)"
        if { [[ "$module_refcount" =~ ^[0-9]+$ ]] && (( module_refcount > 0 )); }; then
          log "DRM module became busy (refcount $module_refcount); uninstall cannot safely continue"
        elif (( rmmod_rc == 124 || rmmod_rc == 137 )); then
          fail "rmmod did not finish within 10s; the module and integration files were left in place"
        else
          fail "could not unload the managed module (exit $rmmod_rc); the integration files were left in place"
        fi
      fi
    fi
  fi
fi

# A successful Cask upgrade must never delete the on-disk module, controller,
# systemd units or ownership state while the kernel still has the module loaded.
# Otherwise the next install cannot verify or unload the resident build.
if [[ -d "/sys/module/$MODULE_NAME" ]]; then
  loaded_version="$(cat "/sys/module/$MODULE_NAME/version" 2>/dev/null || true)"
  module_refcount="$(cat "/sys/module/$MODULE_NAME/refcnt" 2>/dev/null || true)"
  [[ "$module_refcount" =~ ^[0-9]+$ ]] || module_refcount=unknown
  fail "vibeshine_drm remains loaded (version ${loaded_version:-unknown}, refcount $module_refcount); refusing to remove module files, helpers, state or systemd units. Close all virtual displays and retry; if the compositor still holds the module, reboot and retry. No integration files were removed"
fi

log "checking ownership of installed systemd units"
UNIT_DIR="/etc/systemd/system"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  unit_path="$UNIT_DIR/$unit"
  [[ -e "$unit_path" || -L "$unit_path" ]] || continue
  [[ -f "$unit_path" && ! -L "$unit_path" ]] || fail "refusing unsafe systemd unit path: $unit_path"
  expected_unit_sha="$(state_value "unit_${unit}_sha256")"
  if [[ ! "$expected_unit_sha" =~ ^[0-9a-f]{64}$ ]]; then
    if [[ "$STATE_TRUSTED" != "1" ]]; then
      log "no trustworthy ownership record for $unit; preserving the unverified unit"
      continue
    fi
    fail "no ownership record for $unit; leaving it untouched"
  fi
  actual_unit_sha="$(sha256sum "$unit_path" | awk '{print $1}')"
  [[ "$actual_unit_sha" == "$expected_unit_sha" ]] || fail "$unit was modified outside this Cask; leaving it untouched"
  rm -f -- "$unit_path"
done
if command -v systemctl >/dev/null 2>&1; then
  systemctl_bounded 30 "reloading systemd after unit removal" daemon-reload
fi

MODULES_DIR="$DRM_ROOT/modules"
if [[ -e "$MODULES_DIR" || -L "$MODULES_DIR" ]]; then
  if [[ "$STATE_TRUSTED" != "1" || "$MODULE_UNVERIFIED_LOADED" == "1" ]]; then
    log "preserving module files because Cask ownership cannot be verified"
  else
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
          if [[ "$STATE_TRUSTED" != "1" ]]; then
            log "no trustworthy ownership record for $helper_name; preserving the unverified helper"
            continue
          fi
          [[ "$helper_name" == "vibeshine-drmctl" && "$(state_value format)" == "1" ]] || fail "no ownership record for $helper_name; leaving it untouched"
        else
          actual_helper_sha="$(sha256sum "$helper" | awk '{print $1}')"
          [[ "$actual_helper_sha" == "$expected_helper_sha" ]] || fail "$helper_name was modified outside this Cask; leaving it untouched"
        fi
        rm -f -- "$helper"
      done
      ;;
    state)
      remove_owned_selinux_fcontext
      [[ ! -L "$STATE_FILE" ]] || fail "refusing symbolic-link state file"
      rm -f -- "$STATE_FILE"
      ;;
  esac
  rmdir "$path" 2>/dev/null || true
done
if [[ "$STATE_TRUSTED" != "1" ]]; then
  log "installation state was unavailable; any unverified module, unit or helper files were preserved"
fi
log "removed verified Vibeshine DRM integration files"
log "Preserved signing keys in $DRM_ROOT/keys"
