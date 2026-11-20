#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 OUTPUT_ARCHIVE VERIFIED_SOURCE_ARCHIVE" >&2
    exit 2
fi

output="$1"
source_archive="$2"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
payload_dir="$script_dir/../cask-payload"
integration_dir="$script_dir/../integration"
test -d "$payload_dir"
test -d "$integration_dir"
test -s "$source_archive"
version_root="$(tar -tzf "$source_archive" | sed -n '1{s,/.*,,;p;}')"
[[ "$version_root" =~ ^Vibepollo-[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Unexpected source archive root: $version_root" >&2
    exit 1
}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source_members="$(tar -tzf "$source_archive")"
packaging_root="$version_root/third-party/libvirtualdisplay-linux/linux/packaging"
if ! grep -Fqx "$packaging_root/vibeshine-vkms" <<< "$source_members"; then
    # Compatibility with releases predating the Linux-specific submodule.
    packaging_root="$version_root/third-party/libvirtualdisplay/linux/packaging"
fi
for file in vibeshine-vkms vibeshine-vkms-quiesce; do
    grep -Fqx "$packaging_root/$file" <<< "$source_members" || {
        echo "Missing Linux libvirtualdisplay packaging helper: $packaging_root/$file" >&2
        exit 1
    }
    tar -xOzf "$source_archive" "$packaging_root/$file" > "$tmp/$file"
    test -s "$tmp/$file"
    chmod 0755 "$tmp/$file"
done
cp "$payload_dir/install.sh" "$tmp/install.sh"
cp "$payload_dir/install-complete.sh" "$tmp/install-complete.sh"
cp "$payload_dir/uninstall.sh" "$tmp/uninstall.sh"
cp "$payload_dir/uninstall-complete.sh" "$tmp/uninstall-complete.sh"
cp "$payload_dir/vibepollo-askpass" "$tmp/vibepollo-askpass"
# Guard the uninstall contract: a desktop-held DRM reference must defer the
# unload safely, never force-remove a module that the compositor still uses.
grep -Fq 'module_refcount="$(cat "/sys/module/$MODULE_NAME/refcnt" 2>/dev/null || true)"' "$tmp/uninstall.sh"
grep -Fq 'Leaving it loaded until reboot' "$tmp/uninstall.sh"
# Keep SELinux executable labeling persistent and owned by the Cask lifecycle.
grep -Fq 'semanage fcontext -a -f f -t bin_t' "$tmp/install.sh"
grep -Fq 'selinux_fcontext_owned=%s' "$tmp/install.sh"
grep -Fq 'remove_owned_selinux_fcontext' "$tmp/uninstall.sh"
# Keep the broker endpoint compatible with Vibepollo's root-owned socket check.
grep -Fq 'SocketUser=root' "$integration_dir/vibeshine-vkms-control.socket"
grep -Fq 'SocketGroup=@VIBESHINE_SOCKET_GROUP@' "$integration_dir/vibeshine-vkms-control.socket"
grep -Fq 'SocketMode=0660' "$integration_dir/vibeshine-vkms-control.socket"
grep -Fq 'ExecStart=/var/lib/vibepollo/drm/bin/vibeshine-vkms-peercred /var/lib/vibepollo/drm/bin/vibeshine-vkms control' "$integration_dir/vibeshine-vkms-control@.service"
grep -Fq 'SOCKET_GROUP="$(id -gn "$SOCKET_USER")"' "$tmp/install.sh"
cp "$payload_dir/vibeshine-drmctl" "$tmp/vibeshine-drmctl"
for file in vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service; do
    cp "$integration_dir/$file" "$tmp/$file"
done
chmod 0755 "$tmp/install.sh" "$tmp/install-complete.sh" "$tmp/uninstall.sh" "$tmp/uninstall-complete.sh" "$tmp/vibepollo-askpass" "$tmp/vibeshine-drmctl"
chmod 0644 "$tmp/vibeshine-vkms.service" "$tmp/vibeshine-vkms-control.socket" "$tmp/vibeshine-vkms-control@.service"

mkdir -p -- "$(dirname -- "$output")"
epoch="${SOURCE_DATE_EPOCH:-0}"
tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
    -C "$tmp" -cf - install.sh install-complete.sh uninstall.sh uninstall-complete.sh vibepollo-askpass vibeshine-drmctl vibeshine-vkms vibeshine-vkms-quiesce \
    vibeshine-vkms.service vibeshine-vkms-control.socket vibeshine-vkms-control@.service | gzip -n -1 > "$output"
sha256sum "$output"
echo "Created Cask payload: $output"
