#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 OUTPUT_ARCHIVE" >&2
    exit 2
fi

output="$1"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
payload_dir="$script_dir/../cask-payload"
test -d "$payload_dir"
mkdir -p -- "$(dirname -- "$output")"
epoch="${SOURCE_DATE_EPOCH:-0}"
tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
    -C "$payload_dir" -cf - install.sh uninstall.sh vibeshine-drmctl | gzip -n -1 > "$output"
sha256sum "$output"
echo "Created Cask payload: $output"
