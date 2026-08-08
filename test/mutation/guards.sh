#!/usr/bin/env bash
# Mutation check for the M8 filter guards.
#
# A guard that no test can detect the removal of is indistinguishable from a
# vacuous one. Three separate times during M8 a fully green suite was hiding a
# real defect, so each load-bearing condition gets an explicit kill test.
#
# Each mutation below breaks one invariant; `zig build test` MUST fail for it.
# A surviving mutant means the invariant is unpinned, not that the code is
# fine. Not part of `zig build test` (it edits sources); run it when touching
# the guards.
set -uo pipefail
cd "$(dirname "$0")/../.."

fail=0

mutate() {
  local label="$1" file="$2" pattern="$3"
  cp "$file" "$file.mutbak"
  perl -0pi -e "$pattern" "$file"
  if cmp -s "$file" "$file.mutbak"; then
    echo "SKIP  $label (pattern did not apply — was the code refactored?)"
    fail=1
  elif zig build test > /dev/null 2>&1; then
    echo "ALIVE $label — mutation survived, the invariant is NOT pinned"
    fail=1
  else
    echo "KILLED $label"
  fi
  mv "$file.mutbak" "$file"
}

G=src/worker/filter/guard.zig
T=src/worker/trim.zig
U=src/worker/turn.zig

mutate "guard: diff-payload skip in hasErrorSignal" "$G" \
  "s/\(t\[0\] == .\+. or t\[0\] == .-.\) and !\(t\.len > 1 and \(t\[1\] == .-. or t\[1\] == .\+.\)\)/false/"

mutate "guard: error signals bail out git/listing" "$G" \
  "s/pub fn shouldSkipOrErrored\(text: \[\]const u8\) bool \{\n    return shouldSkip\(text\) or hasErrorSignal\(text\);/pub fn shouldSkipOrErrored(text: []const u8) bool {\n    return shouldSkip(text);/"

mutate "guard: small-output threshold" "$G" \
  "s/    if \(text\.len < min_bytes\) return true;\n//"

mutate "guard: structured output is never reshaped" "$G" \
  "s/    if \(looksStructured\(text\)\) return true;\n//"

mutate "guard: keepIfSmaller rejects non-savings" "$G" \
  "s/    return if \(compressed\.len < original\.len\) compressed else null;/    return compressed;/"

mutate "trim: UTF-8 boundary walk in byteFallback" "src/worker/trim/text.zig" \
  "s/    while \(front_end > 0 and \(text\[front_end\] & 0xC0\) == 0x80\) front_end -= 1;\n//"

mutate "trim: stats mutex in note()" "$T" \
  "s/        self\.mutex\.lock\(\);\n        defer self\.mutex\.unlock\(\);\n        if \(ev\.filtered\)/        if (ev.filtered)/"

mutate "turn: raw:true bypasses the seam" "$U" \
  "s/if \(input == \.object\) if \(input\.object\.get\(\x22raw\x22\)\) \|v\|/if (false) if (input.object.get(\x22raw\x22)) |v|/"

mutate "turn: seam carries the tool name" "$U" \
  "s/json\.fmt\(tool_name, \.\{\}\), try rawJson\(arena, input\)/json.fmt(\x22\x22, .{}), try rawJson(arena, input)/"

if [ "$fail" -ne 0 ]; then
  echo
  echo "MUTATION CHECK FAILED: at least one invariant is unpinned."
  exit 1
fi
echo
echo "MUTATION CHECK OK: every guard is pinned by a test that detects its removal."
