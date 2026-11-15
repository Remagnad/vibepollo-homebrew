#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# -ne 1 ]]; then echo "Usage: $0 DESTINATION" >&2; exit 2; fi
destination="$1"
mkdir -p "$(dirname "$destination")"
destination="$(cd "$(dirname "$destination")" && pwd -P)/$(basename "$destination")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/vibepollo-cuda-components.XXXXXX")"
staging_dir="${destination}.staging.$$"
trap 'rm -rf "$work_dir" "$staging_dir"' EXIT
download_dir="$work_dir/downloads"
extract_dir="$work_dir/extracted"
merged_dir="$work_dir/cuda"
mkdir -p "$download_dir" "$extract_dir" "$merged_dir"
base_url="https://developer.download.nvidia.com/compute/cuda/redist"
components=(
  "cuda_nvcc|cuda_nvcc/linux-x86_64/cuda_nvcc-linux-x86_64-12.9.86-archive.tar.xz|7a1a5b652e5ef85c82b721d10672fc9a2dbaab44e9bd3c65a69517bf53998c35"
  "cuda_cudart|cuda_cudart/linux-x86_64/cuda_cudart-linux-x86_64-12.9.79-archive.tar.xz|1f6ad42d4f530b24bfa35894ccf6b7209d2354f59101fd62ec4a6192a184ce99"
  "cuda_cccl|cuda_cccl/linux-x86_64/cuda_cccl-linux-x86_64-12.9.27-archive.tar.xz|8b1a5095669e94f2f9afd7715533314d418179e9452be61e2fde4c82a3e542aa"
  "cuda_cuobjdump|cuda_cuobjdump/linux-x86_64/cuda_cuobjdump-linux-x86_64-12.9.82-archive.tar.xz|ee0de40e8c18068bfcc53e73510e7e7a1a80555205347940df67fa525d24452f"
)
fetch_and_extract() {
  local component="$1" relative_path="$2" expected_sha="$3"
  local archive="$download_dir/${component}.tar.xz"
  local component_dir="$extract_dir/$component"
  echo "Downloading $component: $relative_path"
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors --retry-delay 2 \
    --connect-timeout 30 --max-time 600 "$base_url/$relative_path" -o "$archive"
  echo "$expected_sha  $archive" | sha256sum --check -
  mkdir -p "$component_dir"
  tar -xJf "$archive" -C "$component_dir"
  local archive_root
  archive_root="$(find "$component_dir" -mindepth 1 -maxdepth 1 -type d -name '*-archive' -print -quit)"
  if [[ -z "$archive_root" || ! -d "$archive_root" ]]; then
    echo "::error::Unexpected NVIDIA component archive layout: $component" >&2
    find "$component_dir" -maxdepth 2 -print >&2
    return 1
  fi
  cp -a "$archive_root/." "$merged_dir/"
}
pids=()
for spec in "${components[@]}"; do
  IFS='|' read -r component relative_path expected_sha <<<"$spec"
  fetch_and_extract "$component" "$relative_path" "$expected_sha" &
  pids+=("$!")
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
if ((status != 0)); then
  echo "::error::At least one pinned NVIDIA CUDA component failed to download or extract." >&2
  exit 1
fi
cuda_ld_library_path=""
for library_dir in "$merged_dir/lib64" "$merged_dir/lib" "$merged_dir/nvvm/lib64" "$merged_dir/targets/x86_64-linux/lib"; do
  [[ ! -d "$library_dir" ]] || cuda_ld_library_path="${cuda_ld_library_path:+$cuda_ld_library_path:}$library_dir"
done
for required in "$merged_dir/bin/nvcc" "$merged_dir/bin/cuobjdump" "$merged_dir/include/cuda_runtime.h"; do
  [[ -e "$required" ]] || { echo "::error::Missing CUDA component file: $required" >&2; exit 1; }
done
find "$merged_dir" -name 'libcudart.so*' -print -quit | grep -q . || {
  echo "::error::Pinned CUDA components did not provide libcudart." >&2; exit 1;
}
export CUDA_HOME="$merged_dir" CUDA_PATH="$merged_dir"
export PATH="$merged_dir/bin:$PATH"
export LD_LIBRARY_PATH="$cuda_ld_library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
nvcc_version="$("$merged_dir/bin/nvcc" --version)"
[[ "$nvcc_version" == *"release 12.9,"* ]] || {
  echo "::error::Expected CUDA 12.9 nvcc, got: $nvcc_version" >&2; exit 1;
}
printf '%s\n' "$nvcc_version"
cat > "$work_dir/cuda-smoke-test.cu" <<'CU'
#include <cuda_runtime.h>
__global__ void smoke_kernel(int *value) {
  if (threadIdx.x == 0) *value = 129;
}
int main() { return 0; }
CU
"$merged_dir/bin/nvcc" -std=c++17 -gencode arch=compute_61,code=sm_61 \
  -c "$work_dir/cuda-smoke-test.cu" -o "$work_dir/cuda-smoke-test.o"
"$merged_dir/bin/cuobjdump" --list-elf "$work_dir/cuda-smoke-test.o" | tee "$work_dir/cuda-smoke-test-elfs.txt"
grep -q 'sm_61\.' "$work_dir/cuda-smoke-test-elfs.txt" || {
  echo "::error::Minimal CUDA toolkit failed to emit Pascal sm_61 code." >&2; exit 1;
}
mkdir -p "$(dirname "$staging_dir")"
cp -a "$merged_dir" "$staging_dir"
rm -rf "$destination"
mv "$staging_dir" "$destination"
echo "Installed minimal NVIDIA CUDA 12.9.1 build components at: $destination"
du -sh "$destination"
"$destination/bin/nvcc" --version
