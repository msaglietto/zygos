#!/usr/bin/env bash
# Manual smoke for the real Anthropic provider. Requires ANTHROPIC_API_KEY
# (exits 2 = skipped when unset). NEVER run by zig build test / CI — one real
# API call costs money and needs network. Override model: ZYGOS_SMOKE_MODEL.
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build smoke-anthropic
