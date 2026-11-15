#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DRM_ROOT="/var/lib/vibepollo/drm"
KEY_DIR="$DRM_ROOT/keys"
PRIVATE_KEY="$KEY_DIR/mok.key"
CERTIFICATE="$KEY_DIR/MOK.der"

fail() {
  printf 'vibepollo Cask installer: error: %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || fail "this installer must run with root privileges"
[[ "$#" -eq 2 ]] || fail "expected the Formula prefix and staged helper path"
FORMULA_PREFIX="$1"
STAGED_HELPER="$2"

MODULE_FILE="$FORMULA_PREFIX/libexec/vibeshine_drm.ko"
for metadata in kernel-release kernel-build-dir module-version libvirtualdisplay-commit; do
  [[ -f "$FORMULA_PREFIX/libexec/$metadata" && ! -L "$FORMULA_PREFIX/libexec/$metadata" ]] ||
    fail "the vibepollo-drm Formula is incomplete (missing $metadata); reinstall it from source"
done
[[ -f "$MODULE_FILE" && ! -L "$MODULE_FILE" ]] ||
  fail "the vibepollo-drm Formula did not install vibeshine_drm.ko"
[[ -f "$STAGED_HELPER" && ! -L "$STAGED_HELPER" ]] ||
  fail "the Cask's module-control helper is missing"

KERNEL_RELEASE="$(cat "$FORMULA_PREFIX/libexec/kernel-release")"
EXPECTED_VERSION="$(cat "$FORMULA_PREFIX/libexec/module-version")"
KERNEL_BUILD_DIR="$(cat "$FORMULA_PREFIX/libexec/kernel-build-dir")"
SOURCE_COMMIT="$(cat "$FORMULA_PREFIX/libexec/libvirtualdisplay-commit")"
CURRENT_KERNEL="$(uname -r)"

[[ "$KERNEL_RELEASE" == "$CURRENT_KERNEL" ]] ||
  fail "the module was built for $KERNEL_RELEASE, but the running kernel is $CURRENT_KERNEL; run 'brew reinstall --build-from-source vibepollo-drm' and retry"
[[ "$KERNEL_RELEASE" =~ ^[A-Za-z0-9._+-]+$ ]] ||
  fail "the Formula contains an invalid kernel release"
[[ "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "the Formula contains an invalid module version"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  fail "the Formula contains an invalid libvirtualdisplay commit"
[[ -d "$KERNEL_BUILD_DIR" && ! -L "$KERNEL_BUILD_DIR" ]] ||
  fail "the kernel build directory recorded by the Formula is no longer available"

for parent in /var /var/lib /var/lib/vibepollo "$DRM_ROOT" "$KEY_DIR"; do
  [[ ! -L "$parent" ]] || fail "refusing to use a symbolic-link directory: $parent"
done
[[ -d "$KEY_DIR" ]] ||
  fail "copy your existing Secure Boot key pair to $KEY_DIR before installing this Cask"
[[ -f "$PRIVATE_KEY" && ! -L "$PRIVATE_KEY" ]] ||
  fail "the private key is missing: $PRIVATE_KEY"
[[ -f "$CERTIFICATE" && ! -L "$CERTIFICATE" ]] ||
  fail "the DER certificate is missing: $CERTIFICATE"
[[ "$(stat -c '%u' "$KEY_DIR")" == 0 ]] || fail "$KEY_DIR must be owned by root"
[[ "$(stat -c '%u' "$PRIVATE_KEY")" == 0 ]] || fail "$PRIVATE_KEY must be owned by root; copy it with sudo install"
[[ "$(stat -c '%u' "$CERTIFICATE")" == 0 ]] || fail "$CERTIFICATE must be owned by root; copy it with sudo install"
PRIVATE_MODE="$(stat -c '%a' "$PRIVATE_KEY")"
[[ "$PRIVATE_MODE" == "600" || "$PRIVATE_MODE" == "400" ]] ||
  fail "$PRIVATE_KEY must have mode 0600 or 0400"
CERT_MODE="$(stat -c '%a' "$CERTIFICATE")"
[[ "$CERT_MODE" == "644" || "$CERT_MODE" == "444" || "$CERT_MODE" == "600" || "$CERT_MODE" == "400" ]] ||
  fail "$CERTIFICATE has overly permissive file permissions"

OPENSSL_BIN="$(command -v openssl || true)"
[[ -n "$OPENSSL_BIN" ]] || fail "openssl is required"
command -v modinfo >/dev/null 2>&1 || fail "modinfo from kmod is required"
SIGN_FILE="$KERNEL_BUILD_DIR/scripts/sign-file"
[[ -x "$SIGN_FILE" && ! -L "$SIGN_FILE" ]] ||
  fail "the running kernel's scripts/sign-file is unavailable"

KEY_FINGERPRINT="$("$OPENSSL_BIN" pkey -in "$PRIVATE_KEY" -pubout -outform DER 2>/dev/null |
  sha256sum | awk '{print $1}')" ||
  fail "could not read the private signing key"
CERT_FINGERPRINT="$("$OPENSSL_BIN" x509 -inform DER -in "$CERTIFICATE" -pubkey -noout 2>/dev/null |
  "$OPENSSL_BIN" pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" ||
  fail "could not read the DER signing certificate"
[[ -n "$KEY_FINGERPRINT" && "$KEY_FINGERPRINT" == "$CERT_FINGERPRINT" ]] ||
  fail "mok.key and MOK.der are not a matching key pair"

MODULE_NAME="$(modinfo -F name "$MODULE_FILE")"
MODULE_VERSION="$(modinfo -F version "$MODULE_FILE")"
MODULE_VERMAGIC="$(modinfo -F vermagic "$MODULE_FILE" | awk '{print $1}')"
[[ "$MODULE_NAME" == "vibeshine_drm" ]] || fail "the Formula artifact is not vibeshine_drm.ko"
[[ "$MODULE_VERSION" == "$EXPECTED_VERSION" ]] || fail "the module version does not match the Formula metadata"
[[ "$MODULE_VERMAGIC" == "$KERNEL_RELEASE" ]] || fail "the module vermagic does not match the running kernel"

CERT_SERIAL="$("$OPENSSL_BIN" x509 -inform DER -in "$CERTIFICATE" -noout -serial |
  sed 's/^serial=//' | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
[[ -n "$CERT_SERIAL" ]] || fail "could not read the signing certificate serial"

MODULES_DIR="$DRM_ROOT/modules"
DEST_DIR="$MODULES_DIR/$KERNEL_RELEASE"
for path in "$DRM_ROOT" "$MODULES_DIR" "$DEST_DIR" "$DRM_ROOT/bin" "$DRM_ROOT/state"; do
  [[ ! -L "$path" ]] || fail "refusing to use symbolic-link path: $path"
done

if [[ -d /sys/module/vibeshine_drm ]]; then
  LOADED_SRCVERSION="$(cat /sys/module/vibeshine_drm/srcversion 2>/dev/null || true)"
  NEW_SRCVERSION="$(modinfo -F srcversion "$MODULE_FILE" 2>/dev/null || true)"
  if [[ -z "$LOADED_SRCVERSION" || "$LOADED_SRCVERSION" != "$NEW_SRCVERSION" ]]; then
    fail "vibeshine_drm is currently loaded; close virtual displays and unload it before upgrading"
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
  sha256|sha384|sha512|sha224|sha1) ;;
  *) fail "unsupported kernel module-signing hash: $SIGN_HASH" ;;
esac

TMP_DIR="$(mktemp -d /var/tmp/vibepollo-drm-sign.XXXXXX)"
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

cp -- "$MODULE_FILE" "$TMP_DIR/vibeshine_drm.ko"
"$SIGN_FILE" "$SIGN_HASH" "$PRIVATE_KEY" "$CERTIFICATE" "$TMP_DIR/vibeshine_drm.ko"

SIGNED_SERIAL="$(modinfo -F sig_key "$TMP_DIR/vibeshine_drm.ko" 2>/dev/null |
  tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
[[ -n "$SIGNED_SERIAL" && "$SIGNED_SERIAL" == "$CERT_SERIAL" ]] ||
  fail "the signed module does not contain a signature from the configured certificate"

install -d -o root -g root -m 0755 "$DEST_DIR" "$DRM_ROOT/bin" "$DRM_ROOT/state"
[[ ! -L "$DEST_DIR/vibeshine_drm.ko" ]] || fail "refusing to replace a symbolic-link module destination"
install -o root -g root -m 0644 "$TMP_DIR/vibeshine_drm.ko" "$DEST_DIR/vibeshine_drm.ko.new"
mv -f -- "$DEST_DIR/vibeshine_drm.ko.new" "$DEST_DIR/vibeshine_drm.ko"
install -o root -g root -m 0755 "$STAGED_HELPER" "$DRM_ROOT/bin/vibeshine-drmctl"
printf 'kernel=%s\nversion=%s\nlibvirtualdisplay=%s\n' "$KERNEL_RELEASE" "$EXPECTED_VERSION" "$SOURCE_COMMIT" > "$DRM_ROOT/state/vibeshine-drm-install"
chown root:root "$DRM_ROOT/state/vibeshine-drm-install"
chmod 0644 "$DRM_ROOT/state/vibeshine-drm-install"

if command -v mokutil >/dev/null 2>&1; then
  if mokutil --test-key "$CERTIFICATE" >/dev/null 2>&1; then
    printf 'The certificate is present in the shim MOK database.\n'
  else
    printf 'Note: mokutil did not confirm this certificate in shim MOK. It may still be trusted through another kernel keyring; no enrollment was requested.\n'
  fi
fi

printf '\nInstalled and signed vibeshine_drm.ko for %s.\n' "$KERNEL_RELEASE"
printf 'The module was NOT loaded and no service was enabled.\n'
printf 'Load it only when needed with: sudo %s load\n' "$DRM_ROOT/bin/vibeshine-drmctl"
