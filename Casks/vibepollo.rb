cask "vibepollo" do
  version "2.0.6"
  sha256 "f8bb2fdd872de4deb92020787f31bdf2e6722c4cdc2efae18d8345d2a34bcb5a"

  url "https://github.com/Remagnad/vibepollo-homebrew/releases/download/vibepollo-2.0.6/vibepollo-source-2.0.6.tar.gz"
  name "Vibepollo"
  desc "Privileged Linux integration for the Vibepollo streaming host"
  homepage "https://github.com/Nonary/Vibepollo"

  depends_on :linux
  depends_on arch: :x86_64
  depends_on formula: [
    "vibepollo-app",
    "vibepollo-drm",
  ]

  generated_script "vibeshine-drmctl", content: <<~SH
    #!/usr/bin/env bash
    set -Eeuo pipefail

    DRM_ROOT="/var/lib/vibepollo/drm"
    CERTIFICATE="$DRM_ROOT/keys/MOK.der"
    KERNEL_RELEASE="$(uname -r)"
    MODULE_FILE="$DRM_ROOT/modules/$KERNEL_RELEASE/vibeshine_drm.ko"
    MODULE_NAME="vibeshine_drm"

    fail() {
      printf 'vibeshine-drmctl: error: %s\\n' "$*" >&2
      exit 1
    }

    require_root() {
      [[ "$EUID" -eq 0 ]] || fail "run this command with sudo"
    }

    verify_signature() {
      local openssl_bin cert_serial module_serial

      [[ -f "$CERTIFICATE" && ! -L "$CERTIFICATE" ]] ||
        fail "the signing certificate is missing at $CERTIFICATE"
      command -v modinfo >/dev/null 2>&1 || fail "modinfo from kmod is required"
      openssl_bin="$(command -v openssl || true)"
      [[ -n "$openssl_bin" ]] || fail "openssl is required to verify the module signature"

      cert_serial="$("$openssl_bin" x509 -inform DER -in "$CERTIFICATE" -noout -serial |
        sed 's/^serial=//' | tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
      module_serial="$(modinfo -F sig_key "$MODULE_FILE" 2>/dev/null |
        tr -d ':[:space:]' | tr '[:lower:]' '[:upper:]')"
      [[ -n "$cert_serial" && "$module_serial" == "$cert_serial" ]] ||
        fail "the installed module is not signed by the certificate in $CERTIFICATE"
    }

    usage() {
      printf 'Usage: sudo %s {load|unload|status}\\n' "$0" >&2
    }

    action="$1"
    case "$action" in
      load)
        require_root
        [[ -f "$MODULE_FILE" && ! -L "$MODULE_FILE" ]] ||
          fail "no module was installed for the running kernel ($KERNEL_RELEASE)"
        command -v modinfo >/dev/null 2>&1 || fail "modinfo from kmod is required"
        command -v modprobe >/dev/null 2>&1 || fail "modprobe from kmod is required"
        command -v insmod >/dev/null 2>&1 || fail "insmod from kmod is required"
        verify_signature

        file_version="$(modinfo -F version "$MODULE_FILE")"
        if [[ -d "/sys/module/$MODULE_NAME" ]]; then
          loaded_version="$(cat "/sys/module/$MODULE_NAME/version" 2>/dev/null || true)"
          [[ "$loaded_version" == "$file_version" ]] &&
            { printf '%s is already loaded (version %s)\\n' "$MODULE_NAME" "$loaded_version"; exit 0; }
          fail "a different $MODULE_NAME version is already loaded; stop virtual displays and run 'sudo $0 unload' before replacing it"
        fi

        for dependency in $(modinfo -F depends "$MODULE_FILE" | tr ',' ' '); do
          [[ -n "$dependency" ]] || continue
          modprobe "$dependency"
        done

        if ! insmod "$MODULE_FILE"; then
          printf 'The kernel refused the module. Inspect the kernel log with: journalctl -k -b\\n' >&2
          printf 'No Secure Boot key enrollment is attempted by this command.\\n' >&2
          exit 1
        fi
        printf 'Loaded %s for kernel %s\\n' "$MODULE_NAME" "$KERNEL_RELEASE"
        ;;
      unload)
        require_root
        if [[ -d "/sys/module/$MODULE_NAME" ]]; then
          command -v rmmod >/dev/null 2>&1 || fail "rmmod from kmod is required"
          rmmod "$MODULE_NAME" ||
            fail "the module is busy; close Vibepollo virtual displays and retry"
          printf 'Unloaded %s\\n' "$MODULE_NAME"
        else
          printf '%s is not loaded\\n' "$MODULE_NAME"
        fi
        ;;
      status)
        if [[ -d "/sys/module/$MODULE_NAME" ]]; then
          printf '%s is loaded for kernel %s\\n' "$MODULE_NAME" "$KERNEL_RELEASE"
        else
          printf '%s is not loaded\\n' "$MODULE_NAME"
        fi
        if [[ -f "$MODULE_FILE" ]]; then
          printf 'Installed module: %s\\n' "$MODULE_FILE"
        else
          printf 'No module installed for the running kernel\\n'
        fi
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  SH

  generated_script "install.sh", content: <<~SH
    #!/usr/bin/env bash
    set -Eeuo pipefail
    umask 077

    DRM_ROOT="/var/lib/vibepollo/drm"
    KEY_DIR="$DRM_ROOT/keys"
    PRIVATE_KEY="$KEY_DIR/mok.key"
    CERTIFICATE="$KEY_DIR/MOK.der"

    fail() {
      printf 'vibepollo Cask installer: error: %s\\n' "$*" >&2
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
    [[ "$EXPECTED_VERSION" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]] ||
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
      CONFIGURED_HASH="$(sed -n 's/^CONFIG_MODULE_SIG_HASH="\\([A-Za-z0-9_-]*\\)"$/\\1/p' "$CONFIG_FILE" | head -n1)"
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
    printf 'kernel=%s\\nversion=%s\\nlibvirtualdisplay=%s\\n' "$KERNEL_RELEASE" "$EXPECTED_VERSION" "$SOURCE_COMMIT" > "$DRM_ROOT/state/vibeshine-drm-install"
    chown root:root "$DRM_ROOT/state/vibeshine-drm-install"
    chmod 0644 "$DRM_ROOT/state/vibeshine-drm-install"

    if command -v mokutil >/dev/null 2>&1; then
      if mokutil --test-key "$CERTIFICATE" >/dev/null 2>&1; then
        printf 'The certificate is present in the shim MOK database.\\n'
      else
        printf 'Note: mokutil did not confirm this certificate in shim MOK. It may still be trusted through another kernel keyring; no enrollment was requested.\\n'
      fi
    fi

    printf '\\nInstalled and signed vibeshine_drm.ko for %s.\\n' "$KERNEL_RELEASE"
    printf 'The module was NOT loaded and no service was enabled.\\n'
    printf 'Load it only when needed with: sudo %s load\\n' "$DRM_ROOT/bin/vibeshine-drmctl"
  SH

  generated_script "uninstall.sh", content: <<~SH
    #!/usr/bin/env bash
    set -Eeuo pipefail

    DRM_ROOT="/var/lib/vibepollo/drm"
    MODULE_NAME="vibeshine_drm"

    fail() {
      printf 'vibepollo Cask uninstaller: error: %s\\n' "$*" >&2
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

    printf 'Removed Vibeshine DRM integration files.\\n'
    printf 'Preserved signing keys in %s/keys.\\n' "$DRM_ROOT"
  SH

  installer script: {
    executable: "install.sh",
    args: [
      "#{HOMEBREW_PREFIX}/opt/vibepollo-drm",
      "#{staged_path}/vibeshine-drmctl",
    ],
    sudo: true,
  }

  uninstall script: {
    executable: "uninstall.sh",
    sudo: true,
  }

  caveats <<~EOS
    Before installing, copy your existing module-signing key pair to:

      /var/lib/vibepollo/drm/keys/mok.key
      /var/lib/vibepollo/drm/keys/MOK.der

    The private key must be root-owned with mode 0600 (or 0400); the DER
    certificate must also be root-owned. The Cask never generates keys,
    imports certificates, or requests Secure Boot enrollment.

    The module is signed and installed for the currently running kernel, but
    it is not loaded and no service is enabled at boot. Load it manually when
    needed with:

      sudo /var/lib/vibepollo/drm/bin/vibeshine-drmctl load

    Close virtual displays before unloading or uninstalling the module.
    Signing keys are preserved when the Cask is uninstalled.
  EOS
end
