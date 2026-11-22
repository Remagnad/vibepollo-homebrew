#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 VERIFIED_SOURCE_ARCHIVE OUTPUT_HELPER" >&2
  exit 2
fi

source_archive="$1"
output="$2"
[[ -s "$source_archive" ]] || {
  echo "Missing Vibepollo source archive: $source_archive" >&2
  exit 1
}
for tool in cc python3 readelf tar; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required to build the restricted KMS helper" >&2
    exit 1
  }
done

script_dir="$(cd -- "$(dirname -- "\${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
version_root="$(tar -tzf "$source_archive" | sed -n '1{s,/.*,,;p;}')"
[[ "$version_root" =~ ^Vibepollo-[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Unexpected source archive root: $version_root" >&2
  exit 1
}
tar -xzf "$source_archive" -C "$tmp"
source_root="$tmp/$version_root"
helper_source="$source_root/packaging/linux/steamos/local/vibeshine-kms-capture.c"
build_script="$source_root/packaging/linux/steamos/local/build-capture-helper.py"
protocol="$source_root/src/platform/linux/kms_capture_protocol.h"
for file in "$helper_source" "$build_script" "$protocol"; do
  [[ -s "$file" ]] || {
    echo "The selected upstream release lacks required KMS helper source: $file" >&2
    exit 1
  }
done
grep -Fq '#define VIBESHINE_KMS_CAPTURE_HELPER "/var/lib/vibepollo/drm/bin/vibeshine-kms-capture"' "$protocol" || {
  echo "The source archive was not patched for the Homebrew KMS helper path" >&2
  exit 1
}
grep -Fq 'open_card_device' "$helper_source" || {
  echo "The source archive lacks generic physical DRM-card validation" >&2
  exit 1
}
if [[ -d "$source_root/third-party/libvirtualdisplay-linux/linux/vibeshine-drm" ]]; then
  drm_include="$source_root/third-party/libvirtualdisplay-linux/linux/vibeshine-drm"
else
  drm_include="$source_root/third-party/libvirtualdisplay/linux/vibeshine-drm"
fi
[[ -s "$drm_include/vibeshine_drm_uapi.h" ]] || {
  echo "The pinned Linux libvirtualdisplay DRM UAPI header is missing" >&2
  exit 1
}

mkdir -p -- "$(dirname -- "$output")"
python3 "$build_script" --cc cc --output "$output" --drm-include "$drm_include" --readelf readelf

dynamic="$(readelf -dW "$output")"
needed="$(grep -oE '\(NEEDED\).* \[[^]]+\]' <<< "$dynamic" | sed -E 's/.*\[([^]]+)\]/\1/' | sort)"
expected="$(printf '%s\n' libc.so.6 libcap.so.2 libdrm.so.2 | sort)"
[[ "$needed" == "$expected" ]] || {
  echo "Unexpected KMS helper runtime dependencies:" >&2
  printf '%s\n' "$needed" >&2
  exit 1
}
if grep -Eq '\((RPATH|RUNPATH)\)' <<< "$dynamic"; then
  echo "KMS helper must not contain an RPATH/RUNPATH" >&2
  exit 1
fi
chmod 0755 "$output"
echo "Built and verified the restricted KMS capture helper: $output"
