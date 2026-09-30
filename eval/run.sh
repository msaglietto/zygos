#!/bin/sh
# Eval dry-run for the Zygos task command.
# Not part of zig build test. Does not start Harbor and does not spend.
# The only accepted dataset pin is terminal-bench/terminal-bench-2-1.
# `latest` and Terminal-Bench 4.0 (terminal-bench/terminal-bench@4.0.0) are refused.

set -eu

pinned="terminal-bench/terminal-bench-2-1"
dataset="$pinned"
dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry=1
      shift
      ;;
    --dataset)
      shift
      if [ $# -eq 0 ]; then
        echo "eval: missing dataset" >&2
        exit 2
      fi
      dataset="$1"
      shift
      ;;
    --help|-h)
      echo "usage: eval/run.sh [--dry-run] [--dataset terminal-bench/terminal-bench-2-1]"
      exit 0
      ;;
    *)
      echo "eval: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$dataset" != "$pinned" ]; then
  echo "eval: refusing dataset pin '$dataset' (pinned dataset is $pinned)" >&2
  exit 2
fi

inventory_status="blocked"
target="pending-inventory"
inventory_file="eval/image-platforms.json"
if [ -f "$inventory_file" ]; then
  status_line=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$inventory_file" | head -n 1 || true)
  case "$status_line" in
    *ready*) inventory_status="ready" ;;
    *) inventory_status="blocked" ;;
  esac
  triple_line=$(grep -o '"chosen_triple"[[:space:]]*:[[:space:]]*"[^"]*"' "$inventory_file" | head -n 1 || true)
  if [ -n "$triple_line" ]; then
    target=$(printf '%s' "$triple_line" | sed 's/.*"\([^"]*\)"$/\1/')
  fi
fi

if [ "$dry" -eq 1 ]; then
  echo "dataset: $pinned"
  echo "command: zygos task run --offline --workspace <workspace> --out trial.json --events events.jsonl"
  echo "adapter_version: 0.1.0"
  echo "target: $target"
  echo "inventory: $inventory_status"
  exit 0
fi

echo "eval: refusing a live Harbor run until a dated model id and a spend approval exist" >&2
exit 2
