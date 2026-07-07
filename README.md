# Zygos

A single-binary agent harness in Zig. Zygos reimplements the [iii](https://iii.dev)
engine kernel — workers connect over WebSocket and register *functions* and
*triggers* on one message bus — and (in later milestones) ships harness
capabilities as replaceable workers. Wire-compatible with the unmodified iii
SDKs. See `GOAL.md` for the mission, `docs/ARCHITECTURE.md` and
`docs/PROTOCOL.md` for the design, `docs/specs/` for per-module contracts.

## Status: M0 — the kernel

| Criterion | State |
|---|---|
| S1 wire protocol round-trip | ✅ 43 tests (`kernel/protocol.zig`) |
| S2 function catalog, owner CAS | ✅ 12 tests (`kernel/catalog.zig`) |
| S3 invocation router | ✅ 11 tests (`kernel/invocation.zig`) |
| S4 trigger registry | ✅ 14 tests (`kernel/trigger.zig`) |
| S5 keyed byte channels | ✅ 13 tests (`kernel/channel.zig`) |
| S6 unmodified Node SDK e2e | ✅ `test/e2e/node-sdk/run.sh` |

## Build & test

Requires Zig 0.16.0 (and libc — pthread + CSPRNG; macOS or Linux).

```bash
zig build test   # full kernel suite (125+ tests, leak-checked)
zig build        # produces zig-out/bin/zygos
```

## Run

```bash
ZYGOS_PORT=49134 ./zig-out/bin/zygos   # 49134 is the iii SDK default
```

Any iii SDK connects unmodified:

```javascript
import { registerWorker } from 'iii-sdk'
const iii = registerWorker('ws://localhost:49134')
iii.registerFunction('hello::greet', async (input) => ({ hi: input.name }))
```

## S6 end-to-end test (documented run)

`test/e2e/node-sdk/run.sh` builds the binary, starts a kernel on a scratch
port (`ZYGOS_PORT`, default 49142), `npm install`s the **unmodified**
`iii-sdk` package from npm, and runs `e2e.mjs`: worker A registers
`echo::reverse`, worker B invokes it through the kernel and asserts the
result. Exits nonzero on any failure.

```console
$ ./test/e2e/node-sdk/run.sh
[iii] Worker registered with ID: 8f55dac3-0881-4d07-87ca-687ffbd67044
[iii] Worker registered with ID: 2c46efc0-e598-4fd6-8428-4d90e9a302ac
E2E OK: {"reversed":"sogyz"}
S6 e2e passed on port 49142
```

Requires `node` + `npm` on PATH (network on first run for the SDK install).
