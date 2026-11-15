#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# -ne 3 ]]; then echo "Usage: $0 {main|debug} KEEP_DEPENDENCY_CACHE_KEY KEEP_COMPILER_CACHE_KEY" >&2; exit 2; fi
scope="$1" keep_deps_key="$2" keep_compiler_key="$3"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
case "$scope" in
  main) prefixes=("vibepollo-homebrew-deps-ubuntu-24.04-x86_64-v3-" "vibepollo-homebrew-deps-ubuntu-24.04-x86_64-v4-" "vibepollo-ccache-ubuntu-24.04-x86_64-gcc14-") ;;
  debug) prefixes=("vibepollo-homebrew-deps-ubuntu-24.04-x86_64-v3-" "vibepollo-homebrew-deps-ubuntu-24.04-x86_64-v4-" "vibepollo-debug-ccache-ubuntu-24.04-x86_64-gcc14-") ;;
  *) echo "Unknown cache scope: $scope" >&2; exit 2 ;;
esac
command -v gh >/dev/null 2>&1 || { echo "GitHub CLI (gh) is required." >&2; exit 1; }
records="$(gh api --paginate --jq '.actions_caches[]? | [.id, .key, (.size_in_bytes // 0)] | @tsv' "repos/$repository/actions/caches?per_page=100")"
deleted_count=0 deleted_bytes=0
while IFS=$'\t' read -r cache_id cache_key cache_size; do
  [[ -n "$cache_id" && -n "$cache_key" ]] || continue
  [[ "$cache_key" != "$keep_deps_key" && "$cache_key" != "$keep_compiler_key" ]] || continue
  matched=false
  for prefix in "${prefixes[@]}"; do
    if [[ "$cache_key" == "$prefix"* ]]; then matched=true; break; fi
  done
  [[ "$matched" == true ]] || continue
  echo "Deleting obsolete Actions cache: $cache_key ($cache_size bytes)"
  gh api --silent --method DELETE "repos/$repository/actions/caches/$cache_id"
  deleted_count=$((deleted_count + 1))
  deleted_bytes=$((deleted_bytes + cache_size))
done <<<"$records"
echo "Pruned $deleted_count entries; requested reclaim: $deleted_bytes bytes."
