#!/usr/bin/env bash
# U6 exit test (GOAL.md M2): scripted turn through policy -> approval ->
# routing (zygos.zon from a real file) -> budget -> trim with the real bash
# tool, all in one process. No network.
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build e2e-m2
