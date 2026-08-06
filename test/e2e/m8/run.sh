#!/usr/bin/env bash
# S8 exit test (M8): command-aware output compression over REAL git output.
# Builds a scratch git repo, runs the turn loop with the real bash tool, and
# asserts the filters ran, dedup fired, raw:true bypassed the seam, and the
# savings reached the budget ledger. No network.
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build e2e-m8
