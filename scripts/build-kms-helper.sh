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
for tool in cc python3 readelf tar pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required to build the restricted KMS helper" >&2
    exit 1
  }
done

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
version_root="$(tar -tzf "$source_archive" | sed -n '1{s,/.*,,;p;}')"
[[ "$version_root" =~ ^Vibepollo-[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Unexpected source archive root: $version_root" >&2
  exit 1
}
tar -xzf "$source_archive" -C "$tmp"
source_root="$tmp/$version_root"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
helper_source="$source_root/packaging/linux/steamos/local/vibeshine-kms-capture.c"
build_script="$source_root/packaging/linux/steamos/local/build-capture-helper.py"
protocol="$source_root/src/platform/linux/kms_capture_protocol.h"
for file in "$helper_source" "$build_script" "$protocol"; do
  [[ -s "$file" ]] || {
    echo "The selected upstream release lacks required KMS helper source: $file" >&2
    exit 1
  }
done
# The release archive can predate this packaging change. Apply the same
# checked patch here so Cask payload CI can validate a branch before the app
# bottle workflow has republished its source archive. Already-patched archives
# are accepted, but partially patched trees still fail closed.
if ! grep -Fq '#define VIBESHINE_KMS_CAPTURE_HELPER "/var/lib/vibepollo/drm/bin/vibeshine-kms-capture"' "$protocol" ||
   ! grep -Fq 'open_card_device' "$helper_source" ||
   ! grep -Fq 'restricted KMS capture helper is unavailable' "$source_root/src/platform/linux/kmsgrab.cpp"; then
  python3 "$script_dir/apply-kms-homebrew-patch.py" "$source_root"
fi
grep -Fq '#define VIBESHINE_KMS_CAPTURE_HELPER "/var/lib/vibepollo/drm/bin/vibeshine-kms-capture"' "$protocol" ||
  { echo "The source archive was not patched for the Homebrew KMS helper path" >&2; exit 1; }
grep -Fq 'open_card_device' "$helper_source" ||
  { echo "The source archive lacks generic physical DRM-card validation" >&2; exit 1; }
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

# Upstream's build script keeps its hardened compiler flags, but the system
# libdrm headers are not always on the compiler's default include path
# (for example, Ubuntu installs drm.h under /usr/include/libdrm). Wrap the
# compiler with the host pkg-config flags instead of assuming a distro path.
libdrm_cflags="$(pkg-config --cflags libdrm)" || {
  echo "Could not query system libdrm compiler flags with pkg-config" >&2
  exit 1
}
compiler_path="$(command -v cc)"
python3 - "$tmp/kms-helper-cc" "$compiler_path" "$libdrm_cflags" <<'PY'
import pathlib
import shlex
import sys

output, compiler, cflags = sys.argv[1:]
command = [compiler, *shlex.split(cflags)]
path = pathlib.Path(output)
path.write_text("#!/bin/sh\nset -eu\nexec " + shlex.join(command) + ' "$@"\n', encoding="utf-8")
PY
chmod 0755 "$tmp/kms-helper-cc"
python3 "$build_script" --cc "$tmp/kms-helper-cc" --output "$output" --drm-include "$drm_include" --readelf readelf

# Compile and execute upstream's parser/transport regression test against the
# same patched helper source. This runs without file capabilities and verifies
# that malformed requests, physical/virtual driver classification, SCM_RIGHTS
# descriptor transport and capability refusal behave as expected.
helper_test="$source_root/packaging/linux/steamos/tests/test-kms-capture-helper.c"
[[ -s "$helper_test" ]] || {
  echo "The selected upstream release lacks the KMS helper regression test" >&2
  exit 1
}
read -r -a libdrm_flags <<< "$libdrm_cflags"
read -r -a libdrm_libs <<< "$(pkg-config --libs libdrm)"
"$compiler_path" -std=c11 -O2 -Wall -Wextra -Werror \
  -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE -pie \
  -I"$source_root" -I"$drm_include" "${libdrm_flags[@]}" \
  "$helper_test" -o "$tmp/test-kms-capture-helper" \
  "${libdrm_libs[@]}" -lcap
"$tmp/test-kms-capture-helper"

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
