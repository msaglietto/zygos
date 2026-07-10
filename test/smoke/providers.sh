#!/usr/bin/env bash
# X4 manual smoke (docs/specs/providers-smoke.md): two turns on two real
# catalog providers. Slugs from argv, or auto-picked as the first two whose
# key_env is present in the environment. SKIP (exit 0) when fewer than two
# providers are usable — same convention as the anthropic/openai smokes.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ $# -ge 2 ]; then
  exec zig build smoke-providers -- "$1" "$2"
fi

CATALOG="${AI_PROVIDERS_CONFIG:-$HOME/.agents/providers.toml}"
[ -r "$CATALOG" ] || { echo "SMOKE SKIP: no catalog at $CATALOG"; exit 0; }

# Pick the first two entries whose key_env is set in this environment.
SLUGS=()
name="" keyenv=""
while IFS= read -r line; do
  case "$line" in
    '[[providers]]'*) name=""; keyenv="" ;;
    name*=*) name=$(echo "$line" | sed 's/^name[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/') ;;
    key_env*=*)
      keyenv=$(echo "$line" | sed 's/^key_env[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/')
      if [ -n "$name" ] && [ -n "${!keyenv:-}" ]; then
        slug=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')
        SLUGS+=("$slug")
      fi
      ;;
  esac
done < "$CATALOG"

if [ "${#SLUGS[@]}" -lt 2 ]; then
  echo "SMOKE SKIP: fewer than two catalog providers have keys in this env"
  exit 0
fi

echo "smoke-providers: ${SLUGS[0]} + ${SLUGS[1]}"
exec zig build smoke-providers -- "${SLUGS[0]}" "${SLUGS[1]}"
