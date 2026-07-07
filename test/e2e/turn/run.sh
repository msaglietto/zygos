#!/usr/bin/env bash
# T6 exit test runner: build and run the scripted 2-step tool-use turn
# against the full in-process M1 stack. Nonzero exit on any failure.
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build e2e-turn
