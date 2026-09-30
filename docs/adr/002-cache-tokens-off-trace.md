# ADR 002: Cache tokens stay off the trace usage line

## Status

Accepted.

## Context

Providers sometimes report cache reads and cache writes (`cache_read_input_tokens`, `cache_creation_input_tokens`, and the shorter `cache_read_tokens` / `cache_creation_tokens` names). The usage line in `events.jsonl` is produced by `trace_event.zig` `body()` and is byte-stable: `input_tokens` and `output_tokens` only. `docs/specs/trace.md` says that serialization stays byte-identical. `docs/PROTOCOL.md` is the iii frame format. It does not define `events.jsonl`, and it is not the file to edit for this count.

## Decision

When a provider payload carries cache counts, the task path copies them onto `trial.json` (`cache_read_tokens`, `cache_creation_tokens`) and then leaves the provider payload unchanged for the turn driver. The turn driver keeps writing the two-field usage line. Null cache counts are omitted from the trial. A trace field for cache tokens waits on an explicit format change.

## Consequences

A consumer of `events.jsonl` cannot recover cache counts. A consumer of `trial.json` can. Two arms are not comparable by summing the usage line alone when the question is cache spend.
