#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 TAG EXPECTED_COMMIT OUTPUT_TARBALL" >&2
    exit 2
fi

tag="$1"
expected_commit="$2"
output_tarball="$3"
version="${tag#v}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Refusing non-stable or unsupported release tag: $tag" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
source_dir="$workdir/Vibepollo-$version"
mkdir -p "$(dirname "$output_tarball")"

echo "::group::Fetch exact upstream release"
git init "$source_dir"
git -C "$source_dir" remote add origin https://github.com/Nonary/Vibepollo.git
git -C "$source_dir" fetch --depth=1 origin "refs/tags/$tag:refs/tags/$tag"
git -C "$source_dir" checkout --detach "$tag"

actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
    echo "Tag commit mismatch: API=$expected_commit git=$actual_commit" >&2
    exit 1
fi
echo "Vibepollo $version at $actual_commit"
echo "::endgroup::"

# These are the source submodules used by the Linux user-space target.
# Each one is resolved by Git from the gitlink SHA stored in the selected tag.
submodules=(
    third-party/Simple-Web-Server
    third-party/glad
    third-party/inputtino
    third-party/libdisplaydevice
    third-party/libvirtualdisplay
    third-party/moonlight-common-c
    third-party/nanors
    third-party/nv-codec-headers
    third-party/plasma-wayland-protocols
    third-party/tray
    third-party/wayland-protocols
    third-party/wlr-protocols
)

echo "::group::Fetch pinned top-level submodules"
git -C "$source_dir" -c protocol.version=2 submodule update --init --depth=1 -- "${submodules[@]}"
for path in "${submodules[@]}"; do
    expected="$(git -C "$source_dir" ls-tree HEAD -- "$path" | awk '{print $3}')"
    actual="$(git -C "$source_dir/$path" rev-parse HEAD)"
    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        echo "Submodule SHA mismatch at $path: expected=$expected actual=$actual" >&2
        exit 1
    fi
    printf '%s %s\n' "$path" "$actual"
done
echo "::endgroup::"

echo "::group::Fetch required nested moonlight-common-c submodules"
git -C "$source_dir/third-party/moonlight-common-c" \
    -c protocol.version=2 submodule update --init --depth=1 -- enet nanors/deps/simde

for path in enet nanors/deps/simde; do
    expected="$(git -C "$source_dir/third-party/moonlight-common-c" ls-tree HEAD -- "$path" | awk '{print $3}')"
    actual="$(git -C "$source_dir/third-party/moonlight-common-c/$path" rev-parse HEAD)"
    if [[ -z "$expected" || "$actual" != "$expected" ]]; then
        echo "Nested submodule SHA mismatch at moonlight-common-c/$path" >&2
        exit 1
    fi
    printf 'moonlight-common-c/%s %s\n' "$path" "$actual"
done
echo "::endgroup::"

echo "::group::Apply Homebrew Linux port patch"
python3 "$GITHUB_WORKSPACE/scripts/apply-homebrew-patches.py" "$source_dir"
cat > "$source_dir/HOMEBREW-UPSTREAM.json" <<EOF
{
  "upstream": "https://github.com/Nonary/Vibepollo",
  "tag": "$tag",
  "version": "$version",
  "commit": "$actual_commit",
  "port_patch": "scripts/apply-homebrew-patches.py"
}
EOF
echo "::endgroup::"

# A source bundle must not contain .git directories or gitdir pointer files.
find "$source_dir" -name .git -prune -exec rm -rf {} +

epoch="${SOURCE_DATE_EPOCH:-0}"
bundle_name="Vibepollo-$version"
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -C "$workdir" -cf - "$bundle_name" | gzip -n -9 > "$output_tarball"

sha256sum "$output_tarball"
echo "Created source bundle: $output_tarball"
