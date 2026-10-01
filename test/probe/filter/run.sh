#!/usr/bin/env bash
# Filter reality check with a regression floor (M8).
#
# Run this after touching src/worker/filter/* or the guards. It measures the
# filters against real command output in this repo and fails if the overall
# ratio drops below the floor.
#
# The floor exists because this milestone regressed twice from ordinary commit
# messages: prose that quotes a diagnostic was read as a failed command, which
# silently disabled the git filter and cost ~90% of the git log saving with
# every test still green. A ratio nobody re-measures is a ratio that rots.
#
# The probe also exits non-zero when a measured command did not produce its
# output. `git diff` may exit 1 for a non-empty patch; exit 128 (a depth-1
# clone has no HEAD~1) is git's fatal text and must not enter the ratio.
set -uo pipefail
cd "$(dirname "$0")/../../.."

FLOOR="${FILTER_PROBE_FLOOR:-45}"

out="$(zig build filter-probe 2>&1)" || { echo "$out"; exit 1; }
echo "$out"

total_pct="$(echo "$out" | awk '/^TOTAL/ {print $(NF)}' | tr -d '%')"
if [ -z "$total_pct" ]; then
  echo "FILTER PROBE FAIL: could not parse the total ratio"
  exit 1
fi

if [ "$total_pct" -lt "$FLOOR" ]; then
  echo
  echo "FILTER PROBE FAIL: ${total_pct}% saved is below the ${FLOOR}% floor."
  echo "A filter is probably declining on real output — check the 'selected but"
  echo "declined to filter' lines above before assuming the floor is wrong."
  exit 1
fi

echo
echo "FILTER PROBE OK: ${total_pct}% saved (floor ${FLOOR}%)."
