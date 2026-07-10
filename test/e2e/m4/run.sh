#!/usr/bin/env bash
# W6 exit test (GOAL.md M4): leg 1 — a scripted mission with the continuity
# seam auto-logs a SESSIONS.md entry into a temp vault; leg 2 — an external
# MCP client process (this script) speaks newline-JSON over `zygos
# mcp-gateway` stdio and reads that same entry back via tessera tools.
set -euo pipefail
cd "$(dirname "$0")/../../.."

vault=$(mktemp -d)
trap 'rm -rf "$vault"' EXIT

# Leg 1: mission run auto-logs the session entry.
ZYGOS_VAULT_ROOT="$vault" zig build e2e-m4

# Leg 2: external MCP client through the gateway subcommand.
zig build
out=$(printf '%s\n%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tessera_project_status","arguments":{}}}' \
  | ZYGOS_VAULT_ROOT="$vault" ./zig-out/bin/zygos mcp-gateway)

echo "$out" | grep -q '"protocolVersion":"2025-06-18"'      # initialize answered
echo "$out" | grep -q '"tessera_project_status"'            # tools/list has the bridge
echo "$out" | grep -q 'zygos-e2e'                            # the mission's project came back
echo "$out" | grep -q 'mission done'                         # ...with the auto-logged leaving-behind
# Fail-closed check: an unknown tool is a JSON-RPC error, not a result.
err=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"no_such_tool"}}' \
  | ZYGOS_VAULT_ROOT="$vault" ./zig-out/bin/zygos mcp-gateway)
echo "$err" | grep -q '"code":-32602'

echo "M4 E2E OK: mission auto-log read back through the MCP gateway"
