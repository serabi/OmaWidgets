#!/usr/bin/env bash
#
# Which GPU readings the probe is willing to name, and in particular when it
# will name the NVIDIA helper.
#
# The helper decision is the one that cost a working card its readings: see
# issue #2, where /usr/bin/nvidia-smi was present on an AMD machine because
# nvidia-utils is a dependency of hyprland and steam, and reporting it made the
# service skip amdgpu's sysfs counters for a binary that cannot answer.
set -uo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=../scripts/omawidgets-probe-gpu
source ./scripts/omawidgets-probe-gpu

status=0
passed=0

check() {
  local want=$1 what=$2 got=$3
  if [[ $got == "$want" ]]; then
    passed=$((passed + 1))
  else
    printf '     %-54s expected %-22s got %s\n' "$what" "'$want'" "'$got'"
    status=1
  fi
}

stub=$(mktemp "${TMPDIR:-/tmp}/omawidgets-nvidia-smi.XXXXXX")
printf '#!/bin/sh\nexit 0\n' > "$stub"
chmod +x "$stub"
absent="$stub.not-here"
plain=$(mktemp "${TMPDIR:-/tmp}/omawidgets-not-executable.XXXXXX")
trap 'rm -f "$stub" "$plain"' EXIT

check "$stub" "an NVIDIA card with the helper installed uses it" \
  "$(omawidgets_gpu_helper_path nvidia "$stub")"
check "" "an AMD card does not, even with the helper installed" \
  "$(omawidgets_gpu_helper_path amdgpu "$stub")"
check "" "nor does an Intel one on xe" \
  "$(omawidgets_gpu_helper_path xe "$stub")"
check "" "nor i915" \
  "$(omawidgets_gpu_helper_path i915 "$stub")"
check "" "nor radeon" \
  "$(omawidgets_gpu_helper_path radeon "$stub")"
check "" "nouveau is an NVIDIA card on the open driver, which nvidia-smi cannot read" \
  "$(omawidgets_gpu_helper_path nouveau "$stub")"
check "" "an NVIDIA card without the helper installed names nothing" \
  "$(omawidgets_gpu_helper_path nvidia "$absent")"
check "" "a helper that is present but not executable is not one" \
  "$(omawidgets_gpu_helper_path nvidia "$plain")"
check "" "no driver at all names nothing" \
  "$(omawidgets_gpu_helper_path "" "$stub")"

# The vendor names are what the card's title says, so a wrong one is visible.
check "NVIDIA" "0x10de is NVIDIA" "$(omawidgets_gpu_vendor_name 0x10de)"
check "AMD Radeon" "0x1002 is AMD" "$(omawidgets_gpu_vendor_name 0x1002)"
check "Intel Graphics" "0x8086 is Intel" "$(omawidgets_gpu_vendor_name 0x8086)"
check "GPU" "anything else is just a GPU" "$(omawidgets_gpu_vendor_name 0xbeef)"
check "GPU" "and so is nothing" "$(omawidgets_gpu_vendor_name)"

if ((status == 0)); then
  echo "ok   probe-gpu — $passed cases, including the helper gate from #2"
else
  echo "FAIL probe-gpu — see above"
fi
exit $status
