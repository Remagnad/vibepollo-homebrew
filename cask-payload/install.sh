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

[[ "$EUID" -eq 0 ]] || fail "this installer must run with root privileges"
[[ "$#" -eq 3 ]] || fail "expected DRM Formula prefix, app Formula prefix and staged payload directory"
for command_name in stat sha256sum awk modinfo openssl install mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
FORMULA_PREFIX="$1"
APP_PREFIX="$2"
STAGED_DIR="$3"
STAGED_HELPER="$STAGED_DIR/vibeshine-drmctl"
PEERCRED_HELPER="$APP_PREFIX/libexec/vibeshine-vkms-peercred"
MODULE_FILE="$FORMULA_PREFIX/libexec/vibeshine_drm.ko"
for metadata in kernel-release kernel-build-dir module-version libvirtualdisplay-commit; do
  [[ -f "$FORMULA_PREFIX/libexec/$metadata" && ! -L "$FORMULA_PREFIX/libexec/$metadata" ]] ||
    fail "the vibepollo-drm Formula is incomplete (missing $metadata); reinstall it from source"
done
[[ -f "$MODULE_FILE" && ! -L "$MODULE_FILE" ]] || fail "the Formula did not install vibeshine_drm.ko"
[[ -f "$STAGED_HELPER" && ! -L "$STAGED_HELPER" ]] || fail "the Cask module-control helper is missing"
[[ -x "$PEERCRED_HELPER" && ! -L "$PEERCRED_HELPER" ]] || fail "the app Formula lacks vibeshine-vkms-peercred; rebuild vibepollo-app"
for payload in vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  [[ -f "$STAGED_DIR/$payload" && ! -L "$STAGED_DIR/$payload" ]] || fail "Cask pool payload is missing: $payload"
done
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"
command -v getent >/dev/null 2>&1 || fail "getent is required"
SOCKET_USER="${SUDO_USER:-}"
[[ -n "$SOCKET_USER" && "$SOCKET_USER" != root ]] || fail "install from your normal desktop user with sudo; SUDO_USER is required"
getent passwd "$SOCKET_USER" >/dev/null || fail "could not resolve invoking user: $SOCKET_USER"
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
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
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
  [[ "$LOADED_VERSION" == "$EXPECTED_VERSION" ]] || fail "a different vibeshine_drm build is loaded; unload it before installing or upgrading"
  if [[ -n "$MODULE_SRCVERSION" && -n "$LOADED_SRCVERSION" && "$MODULE_SRCVERSION" != "$LOADED_SRCVERSION" ]]; then
    fail "loaded vibeshine_drm source identity differs from Formula artifact"
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
cleanup() { rm -rf -- "$TMP_DIR"; }
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
install -o root -g root -m 0644 "$TMP_DIR/vibeshine_drm.ko" "$DEST_DIR/vibeshine_drm.ko.new"
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
  [[ ! -L "$BIN_DIR/$helper" && ! -L "$BIN_DIR/$helper.new" ]] || fail "refusing symbolic-link helper destination: $BIN_DIR/$helper"
done
install -o root -g root -m 0755 "$STAGED_HELPER" "$BIN_DIR/vibeshine-drmctl.new"
install -o root -g root -m 0755 "$STAGED_DIR/vibeshine-vkms" "$BIN_DIR/vibeshine-vkms.new"
install -o root -g root -m 0755 "$STAGED_DIR/vibeshine-vkms-quiesce" "$BIN_DIR/vibeshine-vkms-quiesce.new"
install -o root -g root -m 0755 "$PEERCRED_HELPER" "$BIN_DIR/vibeshine-vkms-peercred.new"
mv -f -- "$DEST_DIR/vibeshine_drm.ko.new" "$DEST_DIR/vibeshine_drm.ko"
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
  mv -f -- "$BIN_DIR/$helper.new" "$BIN_DIR/$helper"
done
UNIT_DIR="/etc/systemd/system"
install -d -o root -g root -m 0755 "$UNIT_DIR"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  [[ ! -L "$UNIT_DIR/$unit" ]] || fail "refusing symbolic-link systemd unit: $UNIT_DIR/$unit"
done
sed "s/@VIBESHINE_SOCKET_USER@/$SOCKET_USER/g" "$STAGED_DIR/vibeshine-vkms-control.socket" > "$TMP_DIR/vibeshine-vkms-control.socket"
for unit in vibeshine-vkms.service vibeshine-vkms-control@.service; do
  install -o root -g root -m 0644 "$STAGED_DIR/$unit" "$UNIT_DIR/$unit.new"
done
install -o root -g root -m 0644 "$TMP_DIR/vibeshine-vkms-control.socket" "$UNIT_DIR/vibeshine-vkms-control.socket.new"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  mv -f -- "$UNIT_DIR/$unit.new" "$UNIT_DIR/$unit"
done
systemctl daemon-reload

STATE_TMP="$(mktemp "$STATE_DIR/.vibeshine-drm-install.XXXXXX")"
printf 'format=1\nkernel=%s\nmodule_version=%s\nmodule_srcversion=%s\nlibvirtualdisplay=%s\nmodule_sha256=%s\ncertificate_sha256=%s\nmanaged_load=%s\nload_token=%s\n' \
  "$KERNEL_RELEASE" "$EXPECTED_VERSION" "$MODULE_SRCVERSION" "$SOURCE_COMMIT" "$SIGNED_SHA256" "$CERT_SHA256" "$MANAGED_LOAD" "$LOAD_TOKEN" > "$STATE_TMP"
chown root:root "$STATE_TMP"
chmod 0644 "$STATE_TMP"
mv -f -- "$STATE_TMP" "$STATE_FILE"
printf 'socket_user=%s\n' "$SOCKET_USER" >> "$STATE_FILE"
for unit in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
  printf 'unit_%s_sha256=%s\n' "$unit" "$(sha256sum "/etc/systemd/system/$unit" | awk '{print $1}')" >> "$STATE_FILE"
done
for helper in vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce vibeshine-vkms-peercred; do
  printf 'helper_%s_sha256=%s\n' "$helper" "$(sha256sum "$BIN_DIR/$helper" | awk '{print $1}')" >> "$STATE_FILE"
done
chmod 0644 "$STATE_FILE"

if command -v mokutil >/dev/null 2>&1; then
  if mokutil --test-key "$CERTIFICATE" >/dev/null 2>&1; then
    printf 'The certificate is present in the shim MOK database.\n'
  else
    printf 'Note: mokutil did not confirm this certificate in shim MOK. It may still be trusted through another kernel keyring; no enrollment was requested.\n'
  fi
fi
printf '\nInstalled and signed vibeshine_drm.ko for %s.\n' "$KERNEL_RELEASE"
printf 'The module was NOT loaded and no service was enabled.\n'
printf 'Load it only when needed with: sudo %s load\n' "$BIN_DIR/vibeshine-drmctl"
