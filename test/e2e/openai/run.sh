#!/usr/bin/env bash
# Manual smoke for the real openai-compat provider. Requires OPENAI_API_KEY
# (exits 2 = skipped when unset). NEVER run by zig build test / CI — one real
# API call costs money and needs network. Overrides: ZYGOS_SMOKE_MODEL,
# OPENAI_BASE_URL (any chat-completions-compatible endpoint).
set -euo pipefail
cd "$(dirname "$0")/../../.."
zig build smoke-openai
