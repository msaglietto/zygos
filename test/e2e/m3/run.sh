#!/usr/bin/env bash
# V6 exit test (GOAL.md M3): a scripted mission (define -> plan -> execute
# with the real bash tool -> verify -> hard gate) over the full M2+M3 stack,
# then a fresh orchestrator resumes a mid-flight .planning/ substrate and
# finishes it. One process, no network.
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build e2e-m3
