#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
DRM_ROOT="/var/lib/vibepollo/drm"
KEY_DIR="$DRM_ROOT/keys"
PRIVATE_KEY="$KEY_DIR/mok.key"
CERTIFICATE="$KEY_DIR/MOK.der"
MODULES_DIR="$DRM_ROOT/modules"
BIN_DIR="$DRM_ROOT/bin"
STATE_DIR="$DRM_ROOT/state"
STATE_FILE="$STATE_DIR/vibeshine-drm-install"
SELINUX_FCONTEXT_SPEC="$BIN_DIR/(vibeshine-drmctl|vibeshine-vkms|vibeshine-vkms-quiesce|vibeshine-vkms-peercred|vibepollo-lifecycle|vibepollo-user-launch|vibeshine-kms-capture)"
SELINUX_MODULE_FCONTEXT_SPEC="$MODULES_DIR/[^/]+/vibeshine_drm[.]ko"
SELINUX_ACTIVE=0
SELINUX_RULE_OWNED=0
SELINUX_RULE_ADDED=0
SELINUX_MODULE_RULE_OWNED=0
SELINUX_MODULE_RULE_ADDED=0
SELINUX_STATE_COMMITTED=0

fail() { printf 'vibepollo Cask installer: error: %s\n' "$*" >&2; exit 1; }
require_root_directory() {
  local path="$1" mode
  [[ -d "$path" && ! -L "$path" ]] || fail "expected a real directory, not a symlink: $path"
  [[ "$(stat -c '%u' "$path")" == 0 ]] || fail "$path must be owned by root"
  mode="$(stat -c '%a' "$path")"
  (( (8#$mode & 0022) == 0 )) || fail "$path must not be writable by group or others"
}
require_root_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail "expected a regular file, not a symlink: $1"
  [[ "$(stat -c '%u' "$1")" == 0 ]] || fail "$1 must be owned by root"
}
state_value() {
  local key="$1"
  [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE"
}

[[ "$EUID" -eq 0 ]] || fail "Homebrew must run this installer with sudo: true"
[[ "$#" -eq 3 ]] || fail "expected DRM Formula prefix, app Formula prefix and staged payload directory"
for command_name in stat sha256sum awk modinfo openssl install mktemp readelf ldd setcap getcap; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

# systemd starts these helpers from init_t. bin_t is the standard SELinux
# executable type for custom system services without a dedicated policy.
SELINUX_MODE=""
if command -v getenforce >/dev/null 2>&1; then
  SELINUX_MODE="$(getenforce)"
elif [[ -r /sys/fs/selinux/enforce ]]; then
  if [[ "$(cat /sys/fs/selinux/enforce)" == "1" ]]; then SELINUX_MODE="Enforcing"; else SELINUX_MODE="Permissive"; fi
fi
case "$SELINUX_MODE" in
  Enforcing|Permissive)
    SELINUX_ACTIVE=1
    command -v semanage >/dev/null 2>&1 || fail "semanage is required for persistent SELinux labels (install policycoreutils-python-utils)"
    command -v restorecon >/dev/null 2>&1 || fail "restorecon is required to apply SELinux labels"
    ;;
  Disabled|"") ;;
  *) fail "could not determine SELinux mode: $SELINUX_MODE" ;;
esac
PRIOR_SELINUX_RULE_OWNED="$(state_value selinux_fcontext_owned)"
[[ "$PRIOR_SELINUX_RULE_OWNED" == "1" ]] || PRIOR_SELINUX_RULE_OWNED=0
SELINUX_RULE_OWNED="$PRIOR_SELINUX_RULE_OWNED"
PRIOR_SELINUX_MODULE_RULE_OWNED="$(state_value selinux_module_fcontext_owned)"
[[ "$PRIOR_SELINUX_MODULE_RULE_OWNED" == "1" ]] || PRIOR_SELINUX_MODULE_RULE_OWNED=0
SELINUX_MODULE_RULE_OWNED="$PRIOR_SELINUX_MODULE_RULE_OWNED"
FORMULA_PREFIX="$1"
APP_PREFIX="$2"
STAGED_DIR="$3"
STAGED_HELPER="$STAGED_DIR/vibeshine-drmctl"
PEERCRED_HELPER="$APP_PREFIX/libexec/vibeshine-vkms-peercred"
LIFECYCLE_HELPER="$STAGED_DIR/vibepollo-lifecycle"
USER_LAUNCHER="$STAGED_DIR/vibepollo-user-launch"
KMS_CAPTURE_HELPER="$STAGED_DIR/vibeshine-kms-capture"
LIFECYCLE_STATE="$STATE_DIR/vibepollo-lifecycle"
MODULE_FILE="$FORMULA_PREFIX/libexec/vibeshine_drm.ko"
for metadata in kernel-release kernel-build-dir module-version libvirtualdisplay-commit; do
  [[ -f "$FORMULA_PREFIX/libexec/$metadata" && ! -L "$FORMULA_PREFIX/libexec/$metadata" ]] ||
    fail "the vibepollo-drm Formula is incomplete (missing $metadata); reinstall it from source"
done
[[ -f "$MODULE_FILE" && ! -L "$MODULE_FILE" ]] || fail "the Formula did not install vibeshine_drm.ko"
[[ -f "$STAGED_HELPER" && ! -L "$STAGED_HELPER" ]] || fail "the Cask module-control helper is missing"
[[ -x "$PEERCRED_HELPER" && ! -L "$PEERCRED_HELPER" ]] || fail "the app Formula lacks vibeshine-vkms-peercred; rebuild vibepollo-app"
# This helper runs inside a systemd unit with ProtectHome=yes. It must be fully
# static: Homebrew bottle relocation can otherwise point PT_INTERP into /home.
PEERCRED_PROGRAM_HEADERS="$(readelf -lW "$PEERCRED_HELPER" 2>/dev/null)" ||
  fail "could not inspect the app Formula's peercred ELF program headers"
if grep -q "Requesting program interpreter" <<< "$PEERCRED_PROGRAM_HEADERS"; then
  fail "vibeshine-vkms-peercred is dynamically loaded; rebuild vibepollo-app with the static helper fix"
fi
PEERCRED_DYNAMIC_SECTION="$(readelf -dW "$PEERCRED_HELPER" 2>/dev/null)" ||
  fail "could not inspect the app Formula's peercred ELF dynamic section"
if grep -q "(NEEDED)" <<< "$PEERCRED_DYNAMIC_SECTION"; then
  fail "vibeshine-vkms-peercred has dynamic dependencies; rebuild vibepollo-app with the static helper fix"
fi
[[ -f "$KMS_CAPTURE_HELPER" && ! -L "$KMS_CAPTURE_HELPER" ]] ||
  fail "the restricted KMS capture helper is missing from the Cask payload"
KMS_PROGRAM_HEADERS="$(readelf -lW "$KMS_CAPTURE_HELPER" 2>/dev/null)" ||
  fail "could not inspect the KMS capture helper ELF headers"
grep -q "Requesting program interpreter" <<< "$KMS_PROGRAM_HEADERS" ||
  fail "the KMS capture helper must use the host system dynamic loader"
KMS_DYNAMIC_SECTION="$(readelf -dW "$KMS_CAPTURE_HELPER" 2>/dev/null)" ||
  fail "could not inspect the KMS capture helper ELF dependencies"
if grep -Eq '\((RPATH|RUNPATH)\)' <<< "$KMS_DYNAMIC_SECTION"; then
  fail "the KMS capture helper must not contain an RPATH or RUNPATH"
fi
KMS_LDD="$(ldd "$KMS_CAPTURE_HELPER" 2>&1)" ||
  fail "could not resolve KMS capture helper host libraries"
if grep -q "not found" <<< "$KMS_LDD"; then
  fail "KMS capture needs host libdrm.so.2 and libcap.so.2; install the system libdrm and libcap runtime packages"
fi
grep -q 'libdrm\.so\.2 =>' <<< "$KMS_LDD" ||
  fail "KMS capture requires the host system libdrm.so.2 runtime library"
grep -q 'libcap\.so\.2 =>' <<< "$KMS_LDD" ||
  fail "KMS capture requires the host system libcap.so.2 runtime library"
for payload in vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service vibepollo-lifecycle vibepollo-user-launch; do
  [[ -f "$STAGED_DIR/$payload" && ! -L "$STAGED_DIR/$payload" ]] || fail "Cask pool payload is missing: $payload"
done
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"
command -v getent >/dev/null 2>&1 || fail "getent is required"
SOCKET_USER="${SUDO_USER:-}"
[[ -n "$SOCKET_USER" && "$SOCKET_USER" != root ]] || fail "install from your normal desktop user with sudo; SUDO_USER is required"
[[ "$SOCKET_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || fail "the invoking account name contains unsupported characters"
getent passwd "$SOCKET_USER" >/dev/null || fail "could not resolve invoking user: $SOCKET_USER"
command -v id >/dev/null 2>&1 || fail "id is required to resolve the desktop user's private primary group"
SOCKET_GROUP="$(id -gn "$SOCKET_USER")"
SOCKET_GID="$(id -g "$SOCKET_USER")"
[[ "$SOCKET_GROUP" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*$ ]] || fail "the desktop user's primary group name is not valid for a systemd socket"
GROUP_ENTRY="$(getent group "$SOCKET_GROUP" || true)"
[[ -n "$GROUP_ENTRY" ]] || fail "could not resolve the desktop user's primary group: $SOCKET_GROUP"
IFS=: read -r _ _ RESOLVED_SOCKET_GID GROUP_MEMBERS <<< "$GROUP_ENTRY"
[[ "$RESOLVED_SOCKET_GID" == "$SOCKET_GID" ]] || fail "the resolved primary group does not match the invoking user's primary GID"
OTHER_PRIMARY_USERS="$(getent passwd | awk -F: -v gid="$SOCKET_GID" -v user="$SOCKET_USER" '$4 == gid && $1 != user { print $1 }')"
[[ -z "$OTHER_PRIMARY_USERS" ]] || fail "the desktop user's primary group is shared with other accounts ($OTHER_PRIMARY_USERS); refusing to expose the broker to them"
IFS=, read -r -a GROUP_MEMBER_LIST <<< "${GROUP_MEMBERS:-}"
for group_member in "${GROUP_MEMBER_LIST[@]}"; do
  [[ -z "$group_member" || "$group_member" == "$SOCKET_USER" ]] ||
    fail "the desktop user's primary group has additional members ($group_member); refusing to expose the broker to them"
done
if systemctl is-active --quiet vibeshine-vkms.service || systemctl is-active --quiet vibeshine-vkms-control.socket; then
  fail "stop the Vibeshine pool and control socket before upgrading the Cask"
fi
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  existing="/etc/systemd/system/$unit"
  [[ -e "$existing" || -L "$existing" ]] || continue
  [[ -f "$existing" && ! -L "$existing" ]] || fail "refusing unsafe existing unit: $existing"
  expected="$(state_value "unit_${unit}_sha256")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "refusing to replace an unowned existing unit: $unit"
  actual="$(sha256sum "$existing" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "existing unit was modified outside this Cask: $unit"
done
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred vibepollo-lifecycle vibepollo-user-launch vibeshine-kms-capture; do
  existing="$BIN_DIR/$helper"
  [[ -e "$existing" || -L "$existing" ]] || continue
  [[ -f "$existing" && ! -L "$existing" ]] || fail "refusing unsafe existing helper: $existing"
  expected="$(state_value "helper_${helper}_sha256")"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    [[ "$helper" == "vibeshine-drmctl" && "$(state_value format)" == "1" ]] || fail "refusing to replace an unowned helper: $helper"
  else
    actual="$(sha256sum "$existing" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || fail "existing helper was modified outside this Cask: $helper"
  fi
done

KERNEL_RELEASE="$(cat "$FORMULA_PREFIX/libexec/kernel-release")"
EXPECTED_VERSION="$(cat "$FORMULA_PREFIX/libexec/module-version")"
KERNEL_BUILD_DIR="$(cat "$FORMULA_PREFIX/libexec/kernel-build-dir")"
SOURCE_COMMIT="$(cat "$FORMULA_PREFIX/libexec/libvirtualdisplay-commit")"
CURRENT_KERNEL="$(uname -r)"
[[ "$KERNEL_RELEASE" == "$CURRENT_KERNEL" ]] ||
  fail "the module was built for $KERNEL_RELEASE, but the running kernel is $CURRENT_KERNEL; run 'brew reinstall --build-from-source vibepollo-drm' and retry"
[[ "$KERNEL_RELEASE" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "invalid kernel release in Formula metadata"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9a-f]{12}$ ]] || fail "invalid source-qualified module version"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid libvirtualdisplay commit"
SOURCE_PREFIX="$(printf '%.12s' "$SOURCE_COMMIT")"
[[ "$EXPECTED_VERSION" == *+"$SOURCE_PREFIX" ]] || fail "module version does not identify the pinned libvirtualdisplay commit"
[[ -d "$KERNEL_BUILD_DIR" && ! -L "$KERNEL_BUILD_DIR" ]] || fail "recorded kernel build directory is unavailable"
SIGN_FILE="$KERNEL_BUILD_DIR/scripts/sign-file"
[[ -x "$SIGN_FILE" && ! -L "$SIGN_FILE" ]] || fail "the running kernel's scripts/sign-file is unavailable"

for parent in /var /var/lib /var/lib/vibepollo "$DRM_ROOT" "$KEY_DIR"; do require_root_directory "$parent"; done
KEY_DIR_MODE="$(stat -c '%a' "$KEY_DIR")"
(( (8#$KEY_DIR_MODE & 0077) == 0 )) || fail "$KEY_DIR must be private (mode 0700 or stricter)"
require_root_file "$PRIVATE_KEY"
require_root_file "$CERTIFICATE"
PRIVATE_MODE="$(stat -c '%a' "$PRIVATE_KEY")"
[[ "$PRIVATE_MODE" == "600" || "$PRIVATE_MODE" == "400" ]] || fail "$PRIVATE_KEY must have mode 0600 or 0400"
CERT_MODE="$(stat -c '%a' "$CERTIFICATE")"
[[ "$CERT_MODE" == "644" || "$CERT_MODE" == "444" || "$CERT_MODE" == "600" || "$CERT_MODE" == "400" ]] ||
  fail "$CERTIFICATE must have mode 0644, 0444, 0600 or 0400"

KEY_FINGERPRINT="$(
  openssl pkey -passin pass: -in "$PRIVATE_KEY" -pubout -outform DER 2>/dev/null |
    sha256sum | awk '{print $1}'
)" || fail "could not read private key without a passphrase; mok.key must be unencrypted"
CERT_FINGERPRINT="$(
  openssl x509 -inform DER -in "$CERTIFICATE" -pubkey -noout 2>/dev/null |
    openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
)" || fail "could not read DER signing certificate"
[[ -n "$KEY_FINGERPRINT" && "$KEY_FINGERPRINT" == "$CERT_FINGERPRINT" ]] ||
  fail "mok.key and MOK.der are not a matching key pair"

MODULE_NAME="$(modinfo -F name "$MODULE_FILE")"
MODULE_VERSION="$(modinfo -F version "$MODULE_FILE")"
MODULE_VERMAGIC="$(modinfo -F vermagic "$MODULE_FILE" | awk '{print $1}')"
MODULE_SRCVERSION="$(modinfo -F srcversion "$MODULE_FILE" 2>/dev/null || true)"
MODULE_PARAMETERS="$(modinfo -F parm "$MODULE_FILE")"
[[ "$MODULE_NAME" == "vibeshine_drm" ]] || fail "Formula artifact is not vibeshine_drm.ko"
[[ "$MODULE_VERSION" == "$EXPECTED_VERSION" ]] || fail "module version does not match Formula metadata"
[[ "$MODULE_VERMAGIC" == "$KERNEL_RELEASE" ]] || fail "module vermagic does not match running kernel"
[[ "$MODULE_PARAMETERS" == *"vibeshine_drmctl_token:"* ]] ||
  fail "Formula module lacks the controller load-identity parameter; rebuild the Formula"

for path in "$MODULES_DIR" "$BIN_DIR" "$STATE_DIR"; do
  if [[ -e "$path" || -L "$path" ]]; then require_root_directory "$path"; fi
done
if [[ -e "$STATE_FILE" || -L "$STATE_FILE" ]]; then require_root_file "$STATE_FILE"; fi

MANAGED_LOAD=0
LOAD_TOKEN=""
if [[ -d /sys/module/vibeshine_drm ]]; then
  LOADED_VERSION="$(cat /sys/module/vibeshine_drm/version 2>/dev/null || true)"
  LOADED_SRCVERSION="$(cat /sys/module/vibeshine_drm/srcversion 2>/dev/null || true)"
  LOADED_TOKEN="$(cat /sys/module/vibeshine_drm/parameters/vibeshine_drmctl_token 2>/dev/null || true)"
  if [[ "$LOADED_VERSION" != "$EXPECTED_VERSION" ]]; then
    LOADED_REFCOUNT="$(cat /sys/module/vibeshine_drm/refcnt 2>/dev/null || true)"
    [[ "$LOADED_REFCOUNT" =~ ^[0-9]+$ ]] || LOADED_REFCOUNT=unknown
    fail "a different vibeshine_drm build is already loaded (version ${LOADED_VERSION:-unknown}, refcount $LOADED_REFCOUNT). A loaded kernel module cannot be replaced in place; reboot to unload the old build, then retry Cask installation"
  fi
  if [[ -n "$MODULE_SRCVERSION" && -n "$LOADED_SRCVERSION" && "$MODULE_SRCVERSION" != "$LOADED_SRCVERSION" ]]; then
    fail "the loaded vibeshine_drm source identity differs from the new Formula artifact; reboot to unload the old build, then retry Cask installation"
  fi
  PRIOR_LOAD_TOKEN="$(state_value load_token)"
  if [[ "$(state_value kernel)" == "$KERNEL_RELEASE" &&
        "$(state_value module_version)" == "$EXPECTED_VERSION" &&
        "$(state_value managed_load)" == "1" &&
        "$PRIOR_LOAD_TOKEN" =~ ^[0-9a-f]{64}$ &&
        "$LOADED_TOKEN" == "$PRIOR_LOAD_TOKEN" ]]; then
    MANAGED_LOAD=1
    LOAD_TOKEN="$PRIOR_LOAD_TOKEN"
  elif [[ "$(state_value managed_load)" == "1" ]]; then
    printf 'Note: the loaded module no longer carries the recorded controller token; it will not be considered controller-managed.\n' >&2
  fi
fi

CONFIG_FILE="$KERNEL_BUILD_DIR/.config"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="/boot/config-$KERNEL_RELEASE"
SIGN_HASH="sha256"
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIGURED_HASH="$(sed -n 's/^CONFIG_MODULE_SIG_HASH="\([A-Za-z0-9_-]*\)"$/\1/p' "$CONFIG_FILE" | head -n1)"
  [[ -z "$CONFIGURED_HASH" ]] || SIGN_HASH="$CONFIGURED_HASH"
fi
case "$SIGN_HASH" in
  sha1|sha224|sha256|sha384|sha512) ;;
  *) fail "unsupported kernel module-signing hash: $SIGN_HASH" ;;
esac

TMP_DIR="$(mktemp -d /var/tmp/vibepollo-drm-sign.XXXXXX)"
cleanup() {
  rm -rf -- "$TMP_DIR"
  if [[ "$SELINUX_RULE_ADDED" == "1" && "$SELINUX_STATE_COMMITTED" != "1" ]]; then
    semanage fcontext -d -f f "$SELINUX_FCONTEXT_SPEC" >/dev/null 2>&1 || true
    restorecon -F "$BIN_DIR"/vibeshine-drmctl "$BIN_DIR"/vibeshine-vkms "$BIN_DIR"/vibeshine-vkms-quiesce "$BIN_DIR"/vibeshine-vkms-peercred "$BIN_DIR"/vibepollo-lifecycle "$BIN_DIR"/vibepollo-user-launch "$BIN_DIR"/vibeshine-kms-capture >/dev/null 2>&1 || true
  fi
  if [[ "$SELINUX_MODULE_RULE_ADDED" == "1" && "$SELINUX_STATE_COMMITTED" != "1" ]]; then
    semanage fcontext -d -f f "$SELINUX_MODULE_FCONTEXT_SPEC" >/dev/null 2>&1 || true
    restorecon -F "$MODULES_DIR/$KERNEL_RELEASE/vibeshine_drm.ko" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM
cp -- "$MODULE_FILE" "$TMP_DIR/vibeshine_drm.ko"
"$SIGN_FILE" "$SIGN_HASH" "$PRIVATE_KEY" "$CERTIFICATE" "$TMP_DIR/vibeshine_drm.ko"
SIG_ID="$(modinfo -F sig_id "$TMP_DIR/vibeshine_drm.ko" 2>/dev/null || true)"
[[ -n "$SIG_ID" ]] || fail "modinfo cannot find signature metadata on signed module"
SIGNED_SHA256="$(sha256sum "$TMP_DIR/vibeshine_drm.ko" | awk '{print $1}')"
CERT_SHA256="$(sha256sum "$CERTIFICATE" | awk '{print $1}')"

install -d -o root -g root -m 0755 "$MODULES_DIR/$KERNEL_RELEASE" "$BIN_DIR" "$STATE_DIR"
DEST_DIR="$MODULES_DIR/$KERNEL_RELEASE"
[[ ! -L "$DEST_DIR/vibeshine_drm.ko" && ! -L "$DEST_DIR/vibeshine_drm.ko.new" ]] ||
  fail "refusing symbolic-link module destination"
[[ ! -L "$BIN_DIR/vibeshine-drmctl" && ! -L "$BIN_DIR/vibeshine-drmctl.new" ]] ||
  fail "refusing symbolic-link controller destination"
[[ ! -L "$BIN_DIR/vibeshine-kms-capture" && ! -L "$BIN_DIR/vibeshine-kms-capture.new" ]] ||
  fail "refusing symbolic-link KMS helper destination"
install -o root -g root -m 0644 "$TMP_DIR/vibeshine_drm.ko" "$DEST_DIR/vibeshine_drm.ko.new"
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
  [[ ! -L "$BIN_DIR/$helper" && ! -L "$BIN_DIR/$helper.new" ]] || fail "refusing symbolic-link helper destination: $BIN_DIR/$helper"
done
install -o root -g root -m 0755 "$STAGED_HELPER" "$BIN_DIR/vibeshine-drmctl.new"
install -o root -g root -m 0755 "$STAGED_DIR/vibeshine-vkms" "$BIN_DIR/vibeshine-vkms.new"
install -o root -g root -m 0755 "$STAGED_DIR/vibeshine-vkms-quiesce" "$BIN_DIR/vibeshine-vkms-quiesce.new"
install -o root -g root -m 0755 "$PEERCRED_HELPER" "$BIN_DIR/vibeshine-vkms-peercred.new"
install -o root -g root -m 0755 "$KMS_CAPTURE_HELPER" "$BIN_DIR/vibeshine-kms-capture.new"
install -o root -g root -m 0755 "$LIFECYCLE_HELPER" "$BIN_DIR/vibepollo-lifecycle.new"
install -o root -g root -m 0755 "$USER_LAUNCHER" "$BIN_DIR/vibepollo-user-launch.new"
mv -f -- "$DEST_DIR/vibeshine_drm.ko.new" "$DEST_DIR/vibeshine_drm.ko"
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred vibepollo-lifecycle vibepollo-user-launch vibeshine-kms-capture; do
  mv -f -- "$BIN_DIR/$helper.new" "$BIN_DIR/$helper"
done
# The app remains capability-free. Only this dedicated helper receives the
# single permitted capability required to export active KMS framebuffers.
setcap cap_sys_admin=p "$BIN_DIR/vibeshine-kms-capture" ||
  fail "could not assign CAP_SYS_ADMIN to the restricted KMS helper (install the host libcap setcap utility)"
KMS_CAPTURE_CAPS="$(getcap "$BIN_DIR/vibeshine-kms-capture")"
[[ "$KMS_CAPTURE_CAPS" == "$BIN_DIR/vibeshine-kms-capture cap_sys_admin=p" ]] ||
  fail "the KMS helper file capabilities are not exactly cap_sys_admin=p (actual: ${KMS_CAPTURE_CAPS:-none})"
UNIT_DIR="/etc/systemd/system"
install -d -o root -g root -m 0755 "$UNIT_DIR"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  [[ ! -L "$UNIT_DIR/$unit" ]] || fail "refusing symbolic-link systemd unit: $UNIT_DIR/$unit"
done
sed "s/@VIBESHINE_SOCKET_GROUP@/$SOCKET_GROUP/g" "$STAGED_DIR/vibeshine-vkms-control.socket" > "$TMP_DIR/vibeshine-vkms-control.socket"
for unit in vibeshine-vkms.service vibeshine-vkms-control@.service; do
  install -o root -g root -m 0644 "$STAGED_DIR/$unit" "$UNIT_DIR/$unit.new"
done
install -o root -g root -m 0644 "$TMP_DIR/vibeshine-vkms-control.socket" "$UNIT_DIR/vibeshine-vkms-control.socket.new"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  mv -f -- "$UNIT_DIR/$unit.new" "$UNIT_DIR/$unit"
done
systemctl daemon-reload

if [[ "$SELINUX_ACTIVE" == "1" ]]; then
  existing_selinux_context="$(semanage fcontext -l -C | awk -v spec="$SELINUX_FCONTEXT_SPEC" '$1 == spec { print $NF; exit }')"
  if [[ -n "$existing_selinux_context" ]]; then
    IFS=: read -r _ _ existing_selinux_type _ <<< "$existing_selinux_context"
    [[ "$existing_selinux_type" == "bin_t" ]] || fail "an existing SELinux rule assigns the Vibeshine helpers to $existing_selinux_type instead of bin_t; refusing to overwrite it"
    SELINUX_RULE_OWNED="$PRIOR_SELINUX_RULE_OWNED"
  else
    semanage fcontext -a -f f -t bin_t "$SELINUX_FCONTEXT_SPEC" || fail "could not add the persistent SELinux bin_t rule for Vibeshine helpers"
    SELINUX_RULE_ADDED=1
    SELINUX_RULE_OWNED=1
  fi
  for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred vibepollo-lifecycle vibepollo-user-launch vibeshine-kms-capture; do
    restorecon -F "$BIN_DIR/$helper" || fail "could not apply the SELinux executable label to $BIN_DIR/$helper"
    helper_context="$(stat -c '%C' "$BIN_DIR/$helper")"
    IFS=: read -r _ _ helper_type _ <<< "$helper_context"
    [[ "$helper_type" == "bin_t" ]] || fail "SELinux did not label $BIN_DIR/$helper as bin_t (actual context: $helper_context)"
  done

  existing_module_selinux_context="$(semanage fcontext -l -C | awk -v spec="$SELINUX_MODULE_FCONTEXT_SPEC" '$1 == spec { print $NF; exit }')"
  if [[ -n "$existing_module_selinux_context" ]]; then
    IFS=: read -r _ _ existing_module_selinux_type _ <<< "$existing_module_selinux_context"
    [[ "$existing_module_selinux_type" == "modules_object_t" ]] ||
      fail "an existing SELinux rule assigns the Vibeshine DRM module to $existing_module_selinux_type instead of modules_object_t; refusing to overwrite it"
    SELINUX_MODULE_RULE_OWNED="$PRIOR_SELINUX_MODULE_RULE_OWNED"
  else
    semanage fcontext -a -f f -t modules_object_t "$SELINUX_MODULE_FCONTEXT_SPEC" ||
      fail "could not add the persistent SELinux modules_object_t rule for the Vibeshine DRM module"
    SELINUX_MODULE_RULE_ADDED=1
    SELINUX_MODULE_RULE_OWNED=1
  fi
  MODULE_DEST_PATH="$MODULES_DIR/$KERNEL_RELEASE/vibeshine_drm.ko"
  restorecon -F "$MODULE_DEST_PATH" || fail "could not apply the SELinux kernel-module label to $MODULE_DEST_PATH"
  module_context="$(stat -c '%C' "$MODULE_DEST_PATH")"
  IFS=: read -r _ _ module_type _ <<< "$module_context"
  [[ "$module_type" == "modules_object_t" ]] ||
    fail "SELinux did not label $MODULE_DEST_PATH as modules_object_t (actual context: $module_context)"
fi

STATE_TMP="$(mktemp "$STATE_DIR/.vibeshine-drm-install.XXXXXX")"
printf 'format=1\nkernel=%s\nmodule_version=%s\nmodule_srcversion=%s\nlibvirtualdisplay=%s\nmodule_sha256=%s\ncertificate_sha256=%s\nmanaged_load=%s\nload_token=%s\nselinux_fcontext_owned=%s\nselinux_fcontext_spec=%s\nselinux_module_fcontext_owned=%s\nselinux_module_fcontext_spec=%s\n' \
  "$KERNEL_RELEASE" "$EXPECTED_VERSION" "$MODULE_SRCVERSION" "$SOURCE_COMMIT" "$SIGNED_SHA256" "$CERT_SHA256" "$MANAGED_LOAD" "$LOAD_TOKEN" "$SELINUX_RULE_OWNED" "$SELINUX_FCONTEXT_SPEC" "$SELINUX_MODULE_RULE_OWNED" "$SELINUX_MODULE_FCONTEXT_SPEC" > "$STATE_TMP"
chown root:root "$STATE_TMP"
chmod 0644 "$STATE_TMP"
mv -f -- "$STATE_TMP" "$STATE_FILE"
printf 'socket_group=%s\n' "$SOCKET_GROUP" >> "$STATE_FILE"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  printf 'unit_%s_sha256=%s\n' "$unit" "$(sha256sum "/etc/systemd/system/$unit" | awk '{print $1}')" >> "$STATE_FILE"
done
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred vibepollo-lifecycle vibepollo-user-launch vibeshine-kms-capture; do
  printf 'helper_%s_sha256=%s\n' "$helper" "$(sha256sum "$BIN_DIR/$helper" | awk '{print $1}')" >> "$STATE_FILE"
done
chmod 0644 "$STATE_FILE"

# Keep desktop auto-start explicitly opt-in. Preserve an existing choice
# during Cask upgrades; first installation always records it as disabled.
DESKTOP_UID="$(id -u "$SOCKET_USER")"
DESKTOP_HOME="$(getent passwd "$SOCKET_USER" | awk -F: '{print $6}')"
[[ "$DESKTOP_HOME" == /* && "$DESKTOP_HOME" != "/" && "$DESKTOP_HOME" != *$'\n'* ]] ||
  fail "the invoking desktop account has an invalid home directory"
[[ "$APP_PREFIX" == /* && "$APP_PREFIX" != *$'\n'* ]] ||
  fail "invalid Homebrew app Formula prefix"

PRIOR_AUTOSTART_ENABLED=0
if [[ -e "$LIFECYCLE_STATE" || -L "$LIFECYCLE_STATE" ]]; then
  require_root_file "$LIFECYCLE_STATE"
  lifecycle_mode="$(stat -c '%a' "$LIFECYCLE_STATE")"
  (( (8#$lifecycle_mode & 0022) == 0 )) ||
    fail "existing lifecycle state is writable by group or others"
  prior_uid="$(awk -F= '$1 == "desktop_uid" { print $2; exit }' "$LIFECYCLE_STATE")"
  prior_home="$(awk -F= '$1 == "desktop_home" { sub(/^[^=]*=/, ""); print; exit }' "$LIFECYCLE_STATE")"
  [[ "$prior_uid" == "$DESKTOP_UID" ]] ||
    fail "the existing lifecycle state belongs to another desktop account"
  [[ "$prior_home" == "$DESKTOP_HOME" ]] ||
    fail "the desktop home directory changed; migrate the existing autostart entry before upgrading"
  PRIOR_AUTOSTART_ENABLED="$(awk -F= '$1 == "autostart_enabled" { print $2; exit }' "$LIFECYCLE_STATE")"
  [[ "$PRIOR_AUTOSTART_ENABLED" == 0 || "$PRIOR_AUTOSTART_ENABLED" == 1 ]] ||
    fail "existing lifecycle state has an invalid autostart flag"
fi

AUTOSTART_ENTRY_CONTENT="$(cat <<EOF
[Desktop Entry]
Type=Application
Name=Vibepollo
Comment=Start the Vibepollo streaming host with the graphical session
Exec=/var/lib/vibepollo/drm/bin/vibepollo-user-launch
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
)"
AUTOSTART_SHA="$(printf '%s\n' "$AUTOSTART_ENTRY_CONTENT" | sha256sum | awk '{print $1}')"
LIFECYCLE_TMP="$(mktemp "$STATE_DIR/.vibepollo-lifecycle.XXXXXX")"
cat > "$LIFECYCLE_TMP" <<EOF
format=1
desktop_uid=$DESKTOP_UID
desktop_home=$DESKTOP_HOME
app_prefix=$APP_PREFIX
autostart_enabled=$PRIOR_AUTOSTART_ENABLED
autostart_sha256=$AUTOSTART_SHA
EOF
chown root:root "$LIFECYCLE_TMP"
chmod 0644 "$LIFECYCLE_TMP"
mv -f -- "$LIFECYCLE_TMP" "$LIFECYCLE_STATE"
printf 'lifecycle_state_sha256=%s\n' "$(sha256sum "$LIFECYCLE_STATE" | awk '{print $1}')" >> "$STATE_FILE"
chmod 0644 "$STATE_FILE"
SELINUX_STATE_COMMITTED=1

if command -v mokutil >/dev/null 2>&1; then
  if mokutil --test-key "$CERTIFICATE" >/dev/null 2>&1; then
    printf 'The certificate is present in the shim MOK database.\n'
  else
    printf 'Note: mokutil did not confirm this certificate in shim MOK. It may still be trusted through another kernel keyring; no enrollment was requested.\n'
  fi
fi
printf '\nInstalled and signed vibeshine_drm.ko for %s.\n' "$KERNEL_RELEASE"
printf 'The module was NOT loaded; pool units were installed but neither started nor enabled.\n'
printf 'Start the pool only when needed with: sudo systemctl start vibeshine-vkms.service\n'
printf 'To load only the module without starting the pool: sudo %s load\n' "$BIN_DIR/vibeshine-drmctl"
