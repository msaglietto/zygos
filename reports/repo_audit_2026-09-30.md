# Deep Repo Audit: zygos

## Review and implementation update — 2026-10-01

The audit below is a snapshot of `a2a9bf0`, not a description of today's
checkout. This review checked the cited priority paths and their follow-up
commits, built and tested locally, and completed unfinished remediation. It is
not a new full-tree or full-history security audit. The publication boundary
and remaining maintainer tasks are in
[open-source readiness](../documentation/open-source-readiness.md).

Corrections to the original assessment:

- The project already has an MIT license and package inclusion from `b7ec781`.
  Missing licensing was a publication blocker, not a critical runtime exploit.
  The pinned dependency's upstream license was confirmed and copied into
  `THIRD_PARTY_NOTICES.md`; the original inability to verify it is resolved.
- There are nine numbered Medium findings (7–15), not ten. The Low tail
  contains multiple issues per theme and cannot support an exact count of 18.
- Findings 2/3 describe real lifetime hazards, but a stress test alone cannot
  prove their absence. The in-process fix has explicit barrier and send-storm
  regressions; the WebSocket fix was checked against the same lifetime pattern.
- An environment allowlist does not prevent a shell from reading keys on disk.
  An operator token stored under the same user does not close self-approval.
- Not every public page can necessarily connect to loopback under every browser
  security policy. Missing Origin admission was nevertheless a valid boundary
  gap; handshake Origin admission and optional tokens now cover it.
- GOAL Y5 is a real-vault milestone acceptance gate, distinct from permission to
  publish source. No real-vault run or publication was performed for this review.

| Finding | Current status | Evidence / remaining boundary |
|---|---|---|
| 1 license | Resolved before review | `LICENSE`, package paths; pinned dependency notice added. |
| 2 in-process delivery lifetime | Fixed before review | `RetireGate` acquire under registry lock; stop waits before free; named lifetime and send-storm tests. |
| 3 WebSocket delivery lifetime | Fixed before review, integration added | Acquire under connection-table lock; removal retires before queue deinit/free. `addConn` OOM now stops the writer. Real reply/disconnect churn passed; stress alone is not a lifetime proof. |
| 4 browser admission / bus auth | Implemented before review, integration and docs added | Unknown Origins denied, optional `ZYGOS_TOKEN`; real Origin/token handshake matrix passed. Admitted peers remain fully trusted. |
| 5 inherited secrets / allowed shell | Env filtering fixed before review; posture retained explicitly | Child allowlist, local process-group deadline; shell remains same-UID and allow-by-default. See SECURITY and README. |
| 6 completion self-approval | Open, documented contract | `control.jsonl` remains shell-writable. No claim of independent human authorization. Strong isolation or a policy/attach redesign requires a maintainer contract decision. |
| 7 terminal injection | Initial fix completed | UTF-8/C1 filtering, streamed names and typed trace fields scrubbed; render-level regression and bounded previews. |
| 8 duplicate invocation IDs | Fixed before review | Error result sent to the colliding sender; original pending invocation retained; regression in actor tests. |
| 9 trigger unregister ownership | Fixed before review | Non-owner removal refused; ownerless durable behavior retained; actor/trigger tests. |
| 10 provider max_tokens overflow | Fixed before review | u32 upper bound rejected with line-numbered diagnostic and regression. |
| 11 cron/start concurrency | Follow-up fix completed | Permanent local file + `flock`, descriptor held through run, failure refuses, crash releases; check substrate after lock. Stamp returns formatted slice with PID suffix. |
| 12 shared atomic temp files | Fixed before review | Unique O_EXCL temp files, cleanup and file fsync, concurrent-write tests. Parent-directory fsync/power-loss durability remains unproven. |
| 13 private-host fetch | Partial implementation, explicit remaining risk | Literal/localhost screen with opt-in override. DNS/private aliases and redirects remain unchecked; not an SSRF isolation boundary. |
| 14 runaway shell | Implemented in review | Poll with monotonic deadline, kill process group, reap on failure/OOM, bound wait after output EOF; named deadline regression. |
| 15 remote input buffers | Completed main caps | SSE accumulated-event storage 4 MiB; provider payload 16 MiB; OpenAI tool indexes 0–63; MCP line 1 MiB and read deadline; live previews 256 KiB. MCP write blocking/continuous unmatched notifications remain separate availability work. |
| CI / contributor path | Implemented in review | macOS/Linux workflow; security/contribution/conduct docs and templates; public catalog/quickstart and fixture-only demo. Hosted runs and branch protection remain maintainer tasks. |

The Low findings remain backlog unless the table explicitly identifies a fix.
Do not describe this work as resolving every Low issue, providing a shell
sandbox, a hardened multi-user service, or comprehensive SSRF prevention.
Personal names in historical mission ratifications and fixture listings were
retained as provenance. Gated mission/protocol files were not rewritten to
remove historical private-path references; public onboarding uses repository
references and does not require those private sources.

### Validation for this review

Final validation results are recorded in
[open-source readiness](../documentation/open-source-readiness.md). The tests
added for new behavior were observed red before implementation. Existing
unfinished stream guards were preserved and regression-tested. The first
baseline failed to compile because of the joined SSE documentation comment;
repairing that syntax produced an 874-test green baseline.

---

## Original audit (snapshot with review corrections)

Audit date: 2026-09-30. Head: `a2a9bf0` (branch `t3code/repository-audit`, tracking `upstream/master` at the same content). Method: full read of `src/` (40,134 LOC across 118 Zig files) via five parallel deep-dive passes (kernel, net, worker gates/tools, mission/tessera/mcp, CLI/TUI), independent re-verification of every kept finding against the cited lines, `zig build test` executed (849/849 green), `zig build` executed (binary links), git history scanned (259 commits).

## Executive summary

Zygos is a single-binary agent harness in Zig 0.16 that reimplements the iii engine kernel: workers register functions and triggers over a WebSocket message bus; a mission CLI drives role agents (product-owner/planner/executor/verifier) through an LLM turn loop with policy, approval, budget, routing, and output-trim gates, persisting state to a durable `.planning/` substrate. It serves a single local operator; trust boundaries are the OS user, the loopback bus, the model→tool edge, and outbound provider HTTP.

**Verdict: do not open-source publish yet** — not because the engineering is weak (it is unusually disciplined: fail-closed gates are real and genuinely tested, the suite is leak-checked and offline, docs are honest about gaps), but because (a) there is **no LICENSE file**, so reuse and redistribution terms are missing; (b) two **use-after-free races** sit on the hot delivery paths of the kernel; and (c) the default posture (unauthenticated loopback bus + allow-by-default bash + env-inheriting shell) is dangerous the day it is run on a stranger's machine. **Open-source readiness: blocked** — 1 blocker (LICENSE), publish after ~6 fixes recommended below.

Counts for the numbered findings: **Critical 1, High 5, Medium 9** (15 total). The Low tail is grouped by theme rather than assigned stable individual IDs; the original claim of 18 Low findings was not traceable to that list.

The 3 actions to take first:
1. Add a `LICENSE` (and add it to `build.zig.zon` `paths` — it is commented out there today).
2. Fix the two send-path use-after-frees (`src/net/ws.zig:174-199`, `src/kernel/inproc.zig:74-84`) — refcount or defer-free the entries.
3. Scrub env before `popen` in `src/worker/tools_ops.zig:143` so a model-chauffeured `printenv` cannot exfiltrate the operator's provider keys.

## System map

- **Stack:** Zig 0.16.0, `std` + libc (pthread/CSPRNG), one dependency: `karlseguin/websocket.zig` pinned by URL+hash. Build: `zig build`; test: `zig build test` (849 tests, verified green today; leak-checked via `std.testing.allocator`; no network).
- **Entry points:** bare `zygos` (WS kernel on `127.0.0.1:49134`, any iii SDK connects), `zygos mission start|resume|attach|trace|dashboard` (in-process kernel + workers + optional TUI), `zygos mcp-gateway` (MCP over stdio → tessera bus). No database, no HTTP site, no scheduler in-process.
- **Data stores:** filesystem only — `.planning/` substrate (mission.json, events.jsonl, control.jsonl, threads), notes vault (`ZYGOS_VAULT_ROOT` + `.zygos-shadow` git), `~/.agents/providers.toml` (provider catalog; may carry inline keys).
- **Trust boundaries (documented in `documentation/architecture.md`, verified against code):** OS user → process; local peer → loopback WS bus (**no auth token** — verified `src/net/ws.zig:207-212`); model → tools (policy worker; mission seed is allow — verified `src/worker/mission_boot.zig:255-265`); zygos → provider HTTP (TLS verified on; keys from env/toml, never logged — verified); web_fetch/search → arbitrary remote content.
- **Hot files (git log --stat, last 15 commits):** `documentation/shipping-packet.md`, `src/worker/mission/start.zig`, `src/worker/control.zig` (tail-poll fix), `src/worker/context_thread.zig` (digest cap fix), `src/worker/tessera/vault.zig` (session-read cap fix). Recent work is fixes + a seams refactor (#1) + shipping docs — the repo is in release-prep mode.
- **Intent docs:** present and unusually honest. `docs/PROTOCOL.md` (wire truth), `docs/specs/*` (42 per-module specs), `documentation/*` (implemented trust boundaries, env/secrets inventory, known deferred risks). `documentation/shipping-packet.md` is a prior internal audit; it documents two deferred High risks (gate self-approval, allow-by-default bash) that this audit independently re-derived and confirms below.

## Findings

### src/build.zig.zon + repo root

1. **[CRITICAL] [H] No LICENSE file anywhere in the repo**
   Evidence: `git ls-files | grep -i licen` → empty; `build.zig.zon` `.paths` contains:
   ```
   "src",
   // For example...
   //"LICENSE",
   //"README.md",
   ```
   Impact: the repo is being prepared for public release, but without a project license, reuse and redistribution permissions are unclear. This is a release blocker, not a runtime exploit; memory-safety findings also need resolution before publication.
   Why it survived refute: no LICENSE file exists in the working tree or in any of the 259 history commits (scanned).
   Fix: choose a license (MIT/BSD-2/Apache-2.0 all fit the project's style), commit it at the root, and add it plus README.md to `build.zig.zon` `.paths`.
   Effort: S | Confidence: high

### src/kernel/inproc.zig

2. **[HIGH] [A] inproc.zig:74-84 — use-after-free: kernel-thread `deliver` races `Worker.stop()` → `destroy()`**
   Evidence:
   ```zig
   fn sendFn(ctx: *anyopaque, to: WorkerId, frame: []const u8) actor_mod.SendError!void {
       const self: *Registry = @ptrCast(@alignCast(ctx));
       const worker = blk: {
           self.mutex.lock();
           defer self.mutex.unlock();
           break :blk self.map.get(to);
       };
       if (worker) |w| return w.deliver(frame);
   ```
   and `stop()` (inproc.zig:171-198) does `registry.remove` → `router.join()` → `while (self.handlers_live > 0) wait` → `destroy()` which `gpa.destroy(self)` (inproc.zig:216-217). `handlers_live` counts only spawned handler threads (incremented at :357); a kernel-thread `deliver` in flight is invisible to it. `deliver` (:289-300) dereferences `self.gpa` and `self.q_mutex` — freed memory if `stop()` completes in the window between `map.get` returning the pointer and `deliver` taking the mutex.
   Impact: heap use-after-free / corruption in the agent process on a normal teardown path. Reachable today: `runMcpGateway` stops workers (`gw_worker.stop()`, `undo.stop()`, …) at `src/main.zig:182-185` **while the kernel thread is still running** (`.shutdown` posted and joined only at :186-187), so any in-flight kernel send to a stopping worker hits the window; same pattern at mission-CLI worker teardown.
   Why it survived refute: no refcount, no deferred free, no deliver-count barrier exists anywhere between `map.get` and `destroy`; the `stopping` check inside `deliver` happens after the pointer is already dereferenced.
   Fix: count in-flight delivers like `handlers_live` (increment under registry mutex before releasing it, make `stop()` wait for zero), or move the `*Worker` to refcounted ownership.
   Effort: M | Confidence: high

### src/net/ws.zig

3. **[HIGH] [A] ws.zig:187-199 vs 174-182 — use-after-free: `sendFn` pushes to a `ConnEntry` that `removeConn` can destroy concurrently**
   Evidence:
   ```zig
   self.conns.mutex.unlock();
   entry.queue.push(frame) catch |err| switch (err) { ... };
   ```
   vs
   ```zig
   fn removeConn(self: *Gateway, id: WorkerId) bool {
       self.conns.mutex.lock();
       const removed = self.conns.map.fetchRemove(id);
       self.conns.mutex.unlock();
       const kv = removed orelse return false;
       kv.value.queue.deinit();
       self.gpa.destroy(kv.value);
   ```
   The comment above `removeConn` ("no in-flight write outlives the connection") covers the *writer thread* — `queue.deinit()` joins it — but not an in-flight `push` from the kernel thread, which touches `entry.queue` fields after `destroy`.
   Impact: heap UAF/corruption in the kernel process, triggered by connection churn while the kernel replies to that worker. Attacker: any local process, or **any web page in the operator's browser** (see finding 4) — connect, provoke a reply (register a function another worker invokes), disconnect at the right moment, repeat.
   Why it survived refute: no refcount/graveyard exists; `push` is called after the table mutex is dropped by design (never block the kernel on a socket).
   Fix: refcount `ConnEntry` (acquire under the table lock, release after `push`), or defer destruction to a graveyard drained by the kernel thread.
   Effort: S-M | Confidence: high

4. **[HIGH] [B] ws.zig:207-212 — the WS gateway has no authentication and no Origin check; browsers can join the loopback bus**
   Evidence:
   ```zig
   pub fn init(_: *const websocket.Handshake, conn: *websocket.Conn, gw: *Gateway) !Handler {
       const id = newWorkerId();
       try gw.addConn(id, conn);
       gw.actor.post(.{ .worker_connected = id });
   ```
   The handshake parameter is discarded; `Config` (ws.zig:29-33) binds `127.0.0.1` — but WebSocket is not CORS-gated, so JS on **any public web page** can open `ws://127.0.0.1:49134` and receive a full bus identity: register functions, answer invocations (poison another worker's tool results), bind/unbind triggers (finding 8), squat invocation ids (finding 7), and eat 16 MiB per frame (`max_frame_bytes`, ws.zig:33).
   Impact: remote-web-page → local-agent-harness crossing. `documentation/architecture.md` honestly documents "no auth token" for *local processes*, but the browser drive-by vector is not documented and materially changes the exposure of the published "any iii SDK connects unmodified" default.
   Why it survived refute: searched zygos and the vendored websocket.zig — no token, no Origin check anywhere in the handshake path.
   Fix: before publicizing, require a shared token (query param or header) minted at boot and printed once, plus reject browser `Origin` headers; both are additive and iii-SDK-compatible (SDKs can pass a query param).
   Effort: M | Confidence: high

### src/worker/tools_ops.zig + mission_boot.zig

5. **[HIGH] [B] tools_ops.zig:143 — bash tool inherits the full parent environment; provider keys are readable by the model, and the default policy allows bash**
   Evidence:
   ```zig
   const stream = popen(full_z, "r") orelse return error.ExecFailed;
   ```
   (no env parameter — `/bin/sh -c` inherits everything), combined with the mission policy seed (`src/worker/mission_boot.zig:259-261`):
   ```zig
   rules[0] = .{ .tool = "bash", .verdict = .allow };
   rules[1] = .{ .tool = "web_fetch", .verdict = .allow };
   rules[2] = .{ .tool = "web_search", .verdict = .allow };
   ```
   Provider keys ride the process env (`documentation/variables.md`: `key_env` → `ANTHROPIC_API_KEY` etc.). A model — steered by its own curiosity or by prompt-injected web content flowing through `web_fetch` — runs `printenv`, and the keys come back as tool output into the transcript and `events.jsonl`.
   Impact: secret disclosure + arbitrary command execution under the operator's uid, reachable by any web page the agent fetches. Partially documented (the shipping packet's deferred finding 2; `documentation/automation.md`), so this is a *confirmed, deferred* risk — but it must be a conscious public-launch decision, and the env inheritance half is fixable without changing the execution contract.
   Why it survived refute: no env filtering exists on the popen path; policy matches the tool name only (`src/worker/policy.zig`), never the command.
   Fix (minimum, no contract change): spawn bash with a scrubbed env (drop `*KEY*`/`*TOKEN*`/`*SECRET*` vars, fixed `PATH`); document loudly that fetched text can steer an allowed shell. (Larger fix, human call per the shipping packet: seed `ask` for bash.)
   Effort: S | Confidence: high

6. **[HIGH] [B] cli/mission.zig:570-572 + :767 — the executor can approve its own completion gate by writing `control.jsonl`**
   Evidence: the CLI's control loop tails `<planning>/control.jsonl` and turns each line into bus calls, including `zygos::approvals::resolve` (mission.zig:767, 843); the mission policy allows bash (finding 5); gate ids are deterministic (`a-1` first, `src/worker/approval.zig`). A bash command as simple as `echo '{"cmd":"approve","id":"a-1","approved":true}' >> <planning>/control.jsonl` completes the gate.
   Impact: an unattended (cron) run — the exact Y3 scenario the README documents — can reach `done` with zero human involvement; "the completion gate is the human boundary" is not a boundary while bash is allow. This is the shipping packet's deferred finding 1, independently confirmed.
   Why it survived refute: `controlLoop` is by design an operator attach channel; nothing distinguishes operator-written lines from model-written lines (same uid, same file).
   Fix: human decision per the packet, but for open-source the default should be safe: e.g., isolate the executor under a separate privilege boundary, or require approval before dangerous tool execution. A token in a file, environment, or same-UID socket is not an independent boundary while the executor can access that credential. Merely defaulting bash to `ask` also leaves any allowed MCP tool that can write the control file to consider.
   Effort: M | Confidence: high

### src/tui (model.zig, band.zig, width.zig, frame.zig, term.zig)

7. **[MEDIUM] [B] No ANSI/OSC sanitizer exists on any model/tool output → terminal escape injection into the operator's terminal**
   Evidence: `model.zig:154` (`self.live.appendSlice(self.gpa, bytes) catch {};` — raw delta bytes), `model.zig:374-381` (tool-output preview written via `appendFmt("{s}")`), `band.zig:136-141` (approval ask rendered raw between the TUI's own SGRs), and the deliberate preserve-don't-strip design in `width.zig:113-114`:
   ```
   /// Copy of `s` clipped to at most `cols` cells. ... Escape sequences
   /// after the clip point are still appended (zero-width), so trailing
   /// SGR resets survive truncation.
   ```
   Path: fetched web page / bash stdout / model text → trace tool_result → `partialjson.extractStringField` re-materializes ESC from `\u001b` → preview → `frame.emitRow` → `RealTerm.realWrite` → `write(fd2, …)`. Nothing between ingestion and `write()` removes a single control byte (the only `stripSgr` in `src/tui` is a test helper, `highlight.zig:187`).
   Impact: attacker = any web content the agent fetches or any file it `cat`s; victim = the operator's terminal. OSC 52 (clipboard write/exfil on terminals that allow it), `ESC]8;;` hyperlink spoofing, title/alt-screen hijack, and raw `\r` desyncing the renderer's row accounting. The injectable **approval prompt** is the worst case: a crafted command can restyle itself green/ benign inside the `[y/N]` gate.
   Why it survived refute: verified by reading every render path; `width.zig` measures escapes as zero cells but appends them verbatim.
   Fix: scrub at ingestion — strip ESC-initiated sequences (except the TUI's own), C0 controls except `\n`, and NUL from `onDelta`/`onThinking`/tool previews/log lines; make `truncateToWidth` drop escapes past the clip point rather than carry them.
   Effort: M | Confidence: high

### src/kernel/actor.zig

8. **[MEDIUM] [A] actor.zig:419-428 — a duplicate `invocation_id` invoke is dropped with only a log; the caller hangs forever**
   Evidence:
   ```zig
   self.invocations.add(...) catch |err| {
       log.warn("invoke {s}: {t}, frame dropped", .{ m.function_id, err });
       return;
   };
   ```
   (`invocation.zig:115` returns `error.DuplicateId` when the uuid is parked). No error result is sent to `from`; the timeout belongs to the *first* pending under that uuid, so the colliding caller's wait never fires.
   Impact: any connected worker (unauthenticated — finding 4) can squat a uuid and silently hang another worker's call until forever (not even the invoke timeout applies). Accidental uuid reuse produces the same silent hang.
   Why it survived refute: PROTOCOL.md §1 mandates drop-not-crash only for unknown/duplicate **results**; nothing answers a duplicate **invoke**.
   Fix: reply with an ErrorBody (`duplicate_invocation_id`) to the sender and drop.
   Effort: S | Confidence: high

9. **[MEDIUM] [B] actor.zig:262-265 — `unregistertrigger` has no ownership check; any worker can evict any other worker's bindings**
   Evidence:
   ```zig
   .unregistertrigger => |m| {
       if (!self.triggers.unregisterBinding(m.id, m.trigger_type))
           log.warn("unregistertrigger {s}: unknown or type mismatch", .{m.id});
   },
   ```
   `unregisterBinding` (`trigger.zig:381-388`) removes by id + optional type and never consults `binding.owner`; the actor does not pass `from`. Contrast `unregisterfunction`, which is explicitly CAS-gated (`catalog.zig:337`).
   Impact: a malicious or buggy peer (including a drive-by web page, finding 4) silently disables another worker's trigger bindings — a denial-of-service on the victim's scheduled jobs.
   Why it survived refute: no owner check exists anywhere on this path; the spec is silent, but the function path's CAS shows the intended rigor.
   Fix: pass `from` and require `binding.owner == from or binding.owner == null` (mirroring the catalog CAS).
   Effort: S | Confidence: high

### src/config/providers.zig

10. **[MEDIUM] [A] providers.zig:334-335 + 345 — `max_tokens` upper bound unchecked; `@intCast` panics on values > u32 max**
    Evidence:
    ```zig
    if (b.max_tokens) |mt| if (mt < 1)
        return fail(diag, b.line, "'max_tokens' must be >= 1", error.InvalidCatalog);
    ...
    .max_tokens = if (b.max_tokens) |mt| @intCast(mt) else null,
    ```
    The TOML parser accepts the full i64 range; `Provider.max_tokens` is `?u32`. A plausible "unlimited" typo (`max_tokens = 5000000000`) panics at boot in Debug/ReleaseSafe (`integer cast truncated bits`) and silently wraps in ReleaseFast.
    Impact: operator's own config crashes (or corrupts) the CLI at boot — a stranger's first config edit can look like a zygos bug.
    Why it survived refute: only the lower bound is checked; the parser tests cover `< 1` and temperature bounds but not the upper bound.
    Fix: reject `mt > std.math.maxInt(u32)` in `validateProviders` with the same line-numbered diagnostic; add the test.
    Effort: S | Confidence: high

### src/cli/mission.zig + src/worker/mission_boot.zig + mission_store.zig

11. **[MEDIUM] [A] mission.zig:156-157 + mission_boot.zig:213-215 + mission.zig:710-711 — the unattended-rerun guard is a TOCTOU stat, and `--run-stamp` collides at second granularity, disabling it entirely**
    Evidence:
    ```zig
    if (!queue_mode and zygos.mission_boot.refuseStart(resume_flag, run_stamp, fileExists(gpa, planning, "mission.json"))) {
    ```
    ```zig
    pub fn refuseStart(resume_flag: bool, run_stamp: bool, mission_exists: bool) bool {
        return !resume_flag and !run_stamp and mission_exists;
    }
    ```
    and the stamp is wall-clock `YYYYMMDD-HHMMSS` (mission.zig:710-723). Two failures: (a) the refusal is a single `stat` at CLI boot — the first `mission.json` persist happens seconds later (kernel boot, MCP handshakes, budget configure all precede it), so two cron fires in that window both pass and both run on the same root; (b) with `--run-stamp`, `refuseStart` is false **by construction** and uniqueness rests on a one-second-resolution stamp — two invocations in the same second share the identical planning root with no guard at all.
    Impact: interleaved `mission.json`, double role-turn execution in one workspace, double provider spend — in the exact cron scenario `--run-stamp` exists for (README "Scheduled (unattended) missions"). Compounds with finding 12 (shared `.tmp`).
    Why it survived refute: the in-process `Registry.track` duplicate check is per-process and per-mission-id only; nothing keys the substrate directory to a running process.
    Fix: create the planning root with an `O_EXCL` claim file (pid + boot uuid) *before* kernel boot and refuse if it exists; add sub-second granularity or pid to the stamp.
    Effort: S | Confidence: high

12. **[MEDIUM] [A] mission_store.zig:92 — atomic write uses a fixed `.tmp` name with `CREAT` (no `O_EXCL`); concurrent writers interleave into one tmp file**
    Evidence:
    ```zig
    const fd = c.open(tmp_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    ```
    Same pattern in `fsx.zig` `writeAtomic`. Two writers targeting the same final path (the two processes from finding 11, or two missions on one root) open the *same* tmp file and truncate each other mid-write; whichever renames first can publish an interleaved file. `rename(2)` protects only the single-writer case. (Related durability gap: no `fsync(fd)` before close and no directory fsync — process-crash atomicity holds, power-loss durability does not.)
    Impact: corrupted mission state / SESSIONS.md under exactly the concurrency finding 11 admits.
    Why it survived refute: no lock exists on the planning root anywhere; the registry mutex is per-process.
    Fix: unique tmp suffix (`.{pid}.{counter}`) + `O_EXCL`, `fsync(fd)` before close, unlink tmp on error paths (also fixes tmp residue on ENOSPC).
    Effort: S | Confidence: high

### src/net/web_tools.zig

13. **[MEDIUM] [B] web_tools.zig:60-66 + 292 — web_fetch has no private/loopback/link-local host screening, directly or on redirects**
    Evidence:
    ```zig
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")))
        return error.InvalidUrl;
    if (uri.host == null) return error.InvalidUrl;
    ```
    — scheme + host-presence only, then:
    ```zig
    .redirect_behavior = @enumFromInt(3),
    ```
    `http://localhost`, `127.0.0.1`, `10.x`, `192.168.x`, `169.254.169.254` all fetch (the module's own test blesses `http://localhost:8080/`); redirects are followed 3 hops with no host-class re-check (scheme re-validation does hold in std's client, so `file://` redirects fail — verified).
    Impact: classic agent SSRF — prompt-injected content (or the model itself) can probe internal services and cloud metadata; results flow back into model context and `events.jsonl`. `documentation/permissions.md` documents "Private hosts are not denied," so this is a documented limitation, but it is exactly the class of thing a stranger will run on a cloud laptop.
    Why it survived refute: no denylist/resolution check exists anywhere on the fetch path.
    Fix: resolve the host and reject loopback/private/link-local CIDRs before connect and on every redirect hop (config-gated escape hatch for intentional local endpoints, since tests and ollama-style setups need it).
    Effort: M | Confidence: high

### src/worker/tools_ops.zig

14. **[MEDIUM] [A] tools_ops.zig:8-10 + 143-158 — the bash "timeout" never kills the child; a `sleep infinity` parks a handler thread forever and hangs process teardown**
    Evidence (the contract):
    ```zig
    //! bash runs with cwd = workspace root and no timeout of its own — the
    //! kernel's invocation timeout bounds the bus call.
    ```
    But the kernel timeout only *synthesizes a `timeout` ErrorBody to the caller* (`actor.zig:519` → `completeExceptionally`); the detached handler thread stays blocked in `fread` (`inproc.zig:365` `t.detach()`), the child keeps running, and `Worker.stop()` waits `while (self.handlers_live > 0)` (inproc.zig:195) — one runaway command hangs process exit indefinitely.
    Impact: availability — a hung model-issued command (or a command waiting on a tty) makes the mission CLI unkillable-by-SIGINT-clean-path and leaks the child. Turn-level fail-closed is fine; process-level is not.
    Why it survived refute: no pid tracking, kill, or read deadline exists on the popen path (verified in full).
    Fix: track the child pid (posix_spawn/fork+exec instead of popen, or `popen` + a watcher that `kill(pid, SIGKILL)` at the deadline), or poll `fread`-less with `select` and a deadline.
    Effort: M | Confidence: high

### src/worker/sse.zig, src/worker/openai.zig, src/worker/mcp/transport.zig, src/worker/tui/model.zig (unbounded-buffer cluster)

15. **[MEDIUM] [C] Four remote-input buffers grow without any cap**
    Evidence and sub-locations:
    - `sse.zig:62-64` — `try self.raw.appendSlice(self.gpa, bytes);` — a provider streaming an endless `data:` line with no blank terminator grows the buffer to OOM; the 120 s idle guard does not help because arriving bytes keep poking it (`net/anthropic.zig:157`).
    - `worker/openai.zig:103-104` — `const index = intField(tc, "index") orelse return error.MalformedEvent; while (self.tools.items.len <= index) try self.tools.append(self.gpa, .{});` — a provider-controlled `index` of 1e11 preallocates until the allocator dies (anthropic's assembler is gap-checked and safe — verified).
    - `mcp/transport.zig:143-157` — `readLine` accumulates 1 KiB chunks with no cap; and `mcp/client.zig:171-185` loops on matching-id replies with **no timeout** — an alive-but-silent MCP server blocks the handler thread forever holding the client mutex (README's "never a hang" covers EOF/death, verified — not silence).
    - `tui/model.zig:70-78,149-158` — `live`, `thinking`, `live_tool_args` grow unbounded until a boundary flushes them.
    Impact: a malicious, buggy, or compromised provider endpoint (or MCP child) OOMs or wedges the agent process. Attacker = the endpoint; victim = the operator's run.
    Why it survived refute: no byte budget exists on any of these four paths (verified in full); the existing caps (1 MiB bash, 4 MiB read_file, 2 KiB trace clip) are all tool-side.
    Fix: byte budgets on SSE decode + assembler accumulation (exceed → `BadStream`), reject `index` > a small max as `MalformedEvent`, cap MCP lines (e.g. 1 MiB → `Io`) + optional read deadline, ring-buffer the TUI streams.
    Effort: S (each) | Confidence: high

### Tail — Low findings, clustered by root cause

**L1. Silent truncation / honest-output gaps (worker):** bash output is cut at 1 MiB with no marker or `truncated` flag (`tools_ops.zig:23,151-156` — "Past the cap we keep draining"), unlike web_fetch's `"truncated"` field; steering texts concatenate with no separator (`turn/registry.zig:73`, `turn.zig:656-662` — "focus on X" + "now Y" → "focus on Xnow Y"); `filter/dispatch.zig:44-61` `isMutating` misses prefixed mutations (`git --no-pager add`, `env git add`, `npm install`) so the dedup cache isn't reset (backstopped by the output-hash compare, `filter/cache.zig:62-67`).

**L2. Fail-open accounting / knob defaults (worker):** budget records only provider-reported positive-integer usage (`turn.zig:210-224`) — a provider omitting `usage` records zero and the scope never exhausts (checks fail closed; accounting fails open); the record target is hardcoded `"zygos::budget::record"` (`turn.zig:217`) while checks honor a configurable `budget_function` (`turn/req.zig:84`) — an operator overriding the checker splits check and record across workers; `max_steps:0` → 8 (`turn/req.zig:73-76`) and a budget scope without `max_tokens` = unlimited (`budget.zig:74-79`); SSE `retry:`/unknown-field lines dispatch empty events (`sse.zig:138`) — WHATWG divergence, harmless to both current assemblers.

**L3. Race/reporting nits (kernel + worker):** approval resolve-vs-timeout race reports `resolved:true` to the approver while the requester is denied (`approval.zig:116-131` vs `:144-151` — deny-side correct, human told wrong); channel blocking `Sender.push` maps dupe-OOM to `error.Full` then `unreachable` (`channel.zig:135` + `:176-181`) — OOM-gated panic; shutdown-drained `channel_create` misreported as `OutOfMemory` (`actor.zig:147`); trigger-type replay under OOM swaps the owner with bindings unreplayed, no retry (`trigger.zig:240-246`).

**L4. Info-leak-adjacent logging (net + worker):** full fetch URLs (which may carry userinfo/query tokens) info-logged (`web_tools.zig:171,176,187`); `events.jsonl` records tool inputs/outputs clipped but **unredacted** (`trace.zig:107-111`, `trace_event.zig:118-127`) — with finding 5 this means `printenv` output lands on disk at umask perms (documented: "nothing strips them if a tool prints one", `documentation/variables.md`).

**L5. Concurrency leftovers (mission/tessera/tui):** tessera read-modify-write prepend loses one entry on concurrent `session_close` (`tessera_continuity.zig:122-141`); SESSIONS.md accepts model-controlled section text that can forge `## Session —` headers, poisoning staleness detection (`mission.zig:566-569`, `tessera_continuity.zig:98-104`); TUI Ctrl-C has a single reader whose spawn failure is swallowed and whose blocking bus call can wedge interrupt for up to the 1 h invoke timeout (`cli/mission.zig:330-333,792-797`); `exec_fail_count` never resets on replan (`mission.zig:845-863`) — informational; `context_recall.zig:333-345` loads sources.jsonl unbounded at mission start.

**L6. Transport nits (net):** gzip/deflate bodies are not decompressed — `response.reader()` instead of `readerDecompressing` (`web_tools.zig:313`) — compressed text pages become binary garbage in model context; `http://` provider endpoints send the Bearer key cleartext (config-gated; no warning on non-loopback http — `net/openai.zig:128-137`, `config/providers.zig:332`); timeouts stamp `CLOCK_REALTIME` (`ticker.zig:14-18`) — a backward NTP step stalls idle detection; writer-queue overflow silently drops frames, callers hang until invoke timeout (`writer_queue.zig:16`, `actor.zig:565-566`); `ws.zig addConn` errdefer destroys the entry without `queue.stop()` on OOM (`ws.zig:157-169`); the vendored websocket.zig accepts unmasked client frames (RFC 6455 §5.1 violation — upstream, harmless while loopback-and-unproxied).

**L7. Config/CLI nits:** `ZYGOS_*_MS` negatives parse and apply (`mission_boot.zig:26-29` `envInt` has no lower bound); `AI_PROVIDERS_CONFIG=~/...` is not `~`-expanded (`providers.zig:73`); approval stdin lines longer than the 64-byte buffer leave residue misread as the next verdict (fails toward deny — `cli/mission.zig:760-761`).

**L8. Policy-shape nits (worker):** star rules match the **function_id** namespace, not just tool names (`policy.zig:74` `if (matches(r.tool, tool) or matches(r.tool, function_id))`) — a `"web_*"` rule also allows any bus function starting `web_`, including third-party MCP tools; a `turns::run` request omitting `policy_function` runs wholly ungated and `requires_approval` without `approval_function` auto-approves (`turn.zig:612`, `:279`) — documented as the M1 auto path (`documentation/permissions.md:44`) but it is the composition-level hole in "every gate is fail-closed"; symlink-following escapes file-tool confinement (`tools_ops.zig:6-8` — acknowledged deferral; `read_file`/`write_file` are not offered to mission models today, verified by the tool-list test in `mission/start.zig`, which lowers this to latent).

## Dependencies

| Package | Current | Issue | Action | Reason |
|---|---|---|---|---|
| karlseguin/websocket.zig | pinned `7afc284` via url+hash | The fetched package tarball ships **no LICENSE file** (verified by extracting `~/.cache/zig/p/websocket-0.1.0-*.tar.gz`: only `build.zig`, `build.zig.zon`, `readme.md`, `src`); upstream repo is MIT but the artifact itself is license-silent | Record the license (upstream commit URL + license text) in the repo before publishing; no version bump | Provenance for the sole dependency should be self-contained in the release |
| (stdlib) | Zig 0.16.0 | none | — | `minimum_zig_version = "0.16.0"` matches the toolchain the suite was verified on |

No other dependencies exist (kernel/worker modules are `std`-only by rule). No duplicate versions, no unused imports, no lockfile to audit beyond the zon pin. Clean apart from the license-provenance note.

## Tests

**What the suite actually covers today (verified by running it):** 849/849 green, offline, leak-checked. Genuinely strong: table-driven FSM tests (turn, mission — legal + illegal transitions), fail-closed gate tests (policy unreachable/malformed → deny, budget unreachable → stop, approval timeout → deny, unknown provider slug → boot refusal), catalog owner-CAS reconnect churn, late-result-after-timeout, channel take-once/key gating/TTL, brief lint, resume identity, budget precedence, path-escape lexical rejection, SSE fixtures, MCP gateway error mapping, and three recent regression tests for the perf fixes (tail suffix read, digest cap, session prefix read). Beyond unit: real-command e2e legs (`test/e2e/{turn,m2,m3,m4,m45,m8,node-sdk,timeouts}`) and a **mutation-testing harness** (`test/mutation/guards.sh`) that deletes each load-bearing guard and requires the suite to go red — rare and excellent. Guarded-live smokes (real providers) correctly env-gated and excluded from `zig build test`.

**Proposed tests (smallest per gap; all deterministic):**
- `kernel/inproc.zig`: "stop() during in-flight deliver is use-after-free-free" — hard to unit-test directly; as use a deterministic test that holds a delivery reference while teardown waits, plus a concurrent send/stop stress test. A stress test is probabilistic evidence, not deterministic proof.
- `kernel/actor.zig`: "duplicate invocation_id invoke receives an error result, not silence" — invoke with a parked uuid, assert an ErrorBody frame returns to the caller. Unit. (Fails today.)
- `kernel/actor.zig`: "unregistertrigger from a non-owner is refused" — two fake workers, victim binds, attacker unregisters, assert binding survives. Unit. (Fails today.)
- `config/providers.zig`: "max_tokens above u32 max is a line-numbered catalog error, not a panic" — fixture TOML, assert `InvalidCatalog`. Unit. (Panics today.)
- `cli/mission.zig` / `mission_boot`: "two same-second run-stamps do not share a planning root" (assert uniqueness mechanism) and "a claimed planning root refuses a second start pre-boot" (O_EXCL claim). Unit/integration. (Fails today.)
- `mission_store.zig`: "two concurrent writeAtomic calls to one path never publish interleaved bytes" (spawn two threads, both write distinct patterns, assert final file is exactly one pattern). Integration. (Fails today.)
- `worker/tools_ops.zig`: "bash runs without provider-key env vars" — set a canary env var, run `printenv CANARY`, assert failure/empty. Unit. (Fails today.)
- `tui`: "model deltas containing ESC ] 52 / CSI / raw CR never reach the term writer" — fake term sink, feed poisoned deltas, assert bytes. Unit. (Fails today — nothing to test until the scrubber exists.)
- `net/web_tools.zig`: "fetch to a loopback/private IP is refused, and a redirect to one is refused too" (localhost stub server). Deterministic integration.

**CI gating:** there is **no CI at all** (no `.github/`, nothing else). The repo's own `tests.md` proposes "a hosted required check that runs `zig build test` and `zig fmt --check src/`" — not added. For the public launch this is a must: one workflow, two steps, both already verified green on a clean run today. Leave provider smokes guarded-live (never in CI), exactly as now.

## Open-source readiness

**Verdict: blocked** — one hard blocker and a short fix list.

- **Blocker (Critical):** no LICENSE (finding 1). Nothing else matters legally until this exists.
- **Publish-after-fixes:** findings 2, 3 (memory-safety races on delivery paths), 5 (env scrub — minimum half), 7 (terminal injection), 10, 11, 12 (config crash + cron-safety), plus a CI workflow. Items 4, 6, 13 are posture decisions the maintainer has already framed (shipping packet) — they need *conscious* decisions documented in the README before strangers run this against their provider keys.
- **License compatibility:** project license — none yet (blocker). Sole dependency websocket.zig: MIT per upstream repo; the fetched artifact ships no LICENSE (see Dependencies) — record provenance. No copyleft conflicts possible with a single MIT dep.
- **Secrets and PII scan:** working tree — no API keys, tokens, credentials, or live endpoints found (grepped `sk-`, `api_key`, `key = "`, provider names across `src/`, `test/`, `examples/`, `docs/`; all stubs bind `127.0.0.1`; smokes read keys only from env). Git history — all 259 commits scanned for secret-shaped files and secret-shaped content in likely paths: **nothing found** (`.tokensave/`, `wm`, `.ua`, `CLAUDE.md` are gitignored and never committed). Personal data present but benign: the operator's name appears throughout `GOAL.md`/`README.md`/commit messages ("Mauricio", ratification dates) and as the username in `ls -la` test fixtures (`src/worker/trim.zig:589-592`, `src/worker/filter/listing.zig:99-104`) — scrub or accept. Internal references: private vault paths (`poe.md/Projects/Zygos/DESIGN.md`), `~/Projects/iii` — rewrite as repo-relative before publishing.
- **History hygiene for publish:** 28 "t3 checkpoint" snapshot commits live on side branches (`t3code/*`, visible in `git log --all`), and `harness-bench` carries divergent unreleased features (`zygos task run`, `src/worker/trial.zig`, an 870-test suite per its WORK-LEDGER). Publish `master` only (fresh repo or branch-filtered push), not `--all`.
- **The stranger's path:** documented and it works — verified today from this checkout: `zig build` (binary links), `zig build test` (849 green, offline), `ZYGOS_PORT=... ./zig-out/bin/zygos` (loopback kernel). Zig 0.16.0 requirement stated in README + `minimum_zig_version`. Env knobs fully inventoried in `documentation/variables.md` (best-in-class honesty, including the go-live checklist). Gaps: `test/e2e/node-sdk` needs `node`+`npm` (documented), `docs/ONBOARDING.md` says "579 tests" (stale — now 849) and `tests.md` says 848 (stale by 1); `examples/*/zygos.zon` reference provider slugs that only exist in the maintainer's private `~/.agents/providers.toml` — a stranger cannot run the dogfood examples; a sample `providers.toml` fixture in `examples/` would fix that. No CONTRIBUTING.md / code of conduct / issue templates (Low — but the repo has strong contribution rules in AGENTS.md that a CONTRIBUTING could adapt).
- **Release hygiene:** `.gitignore` complete (build outputs, caches, local agent files excluded); no build artifacts committed; `zig fmt --check src/` clean (verified); CI absent (see Tests).

## What is well-built

- **The fail-closed gates are real, not aspirational** — policy unreachable/malformed/unknown verdicts deny (`worker/turn.zig`, tested at :1282-1382), unreachable budget stops the turn, approval timeout denies and a late resolve cannot resurrect an expired ask (`worker/approval.zig:124` `in_time ands away` the stale state). This is the hardest part of an agent harness and it is done properly.
- **The bounded MPSC inbox with backpressure** (`kernel/actor/inbox.zig`) — producers block, not grow; predicate-loop condvar waits; clean and correct.
- **The mutation-testing harness** (`test/mutation/guards.sh`) that deletes each guard and requires red — and the README's honesty about the M8 lesson ("a fixture proves the algorithm; only a real command proves the wiring").
- **Protocol parse hygiene:** the arena errdefer chain frees on every error path (`protocol/parse.zig:22-25`); duplicate JSON keys reject; iterative `json.Value` parsing (no recursion); out-of-i64 integers become `.number_string` and are rejected — no overflow anywhere on the wire path.
- **Channel security details done right:** constant-time key comparison with fixed length (`kernel/channel.zig:414-417`), take-once endpoints, owner reap.
- **The docs tell the truth about their own gaps** — `documentation/permissions.md` and `variables.md` enumerate what is *not* enforced (symlinks, private hosts, no bus auth, unredacted trace) with the go-live checklist. `documentation/shipping-packet.md` records deferred risks rather than hiding them.
- **Memory discipline:** arena-per-invocation, `std.testing.allocator` everywhere in tests, and the suite is genuinely leak-checked (verified running it).
- **The three recent performance fixes are real and regression-tested** (tail suffix read, digest byte cap, session prefix read) — each with a named test pinning it.

## What I could not verify

- **The races (findings 2, 3) are argued statically, not reproduced** — I verified the interleavings are possible by reading every participating line, but did not run a stress harness (which can also run against vulnerable code; deterministic lifetime barriers are better regression evidence than a stress run alone). A human should treat the two UAFs as real until independently confirmed.
- **`test/e2e/node-sdk`, provider smokes, timeouts leg** were not executed (node-sdk and smokes need network/keys). The node-sdk e2e is the only proof of iii-SDK wire compatibility; I read its script but did not run it.
- **The vendored websocket.zig** was read only in the files needed to trace the handshake/frame/lifecycle claims (proto, server/handshake, buffer), not in full.
- **The `harness-bench` and other `t3code/*` branches** were sampled (WORK-LEDGER, file list), not audited — out of scope for the publish branch.
- **Upstream license text** for websocket.zig could not be confirmed from the fetched artifact (it ships none); confirm against the GitHub repo at the pinned commit before release.
- **Behavior under load** (many concurrent WS connections, mission concurrency beyond two) — no stress runs were performed.

## Out of scope / dropped

Candidates refuted during verification, with the disproof — recorded so the keepers are trusted:

- **`file://` fetch or `file://` redirect via web_fetch** — `validateUrl` rejects non-http(s) (`web_tools.zig:60-66`); std's client rejects non-http(s) redirect targets with `UnsupportedUriScheme` → `HttpFailed`.
- **Search-query URL injection / Brave key leak** — query percent-encoded per byte (`web_tools.zig:370-385`); errors name the env var, never the value (`web_tools.zig:207-214`).
- **Script/style content leaking into model context via htmlToText** — `dropNonContent` drops them whole; fixture tests assert `alert`/`window.__DATA__` absent.
- **Provider keys logged / put on the bus / written to trace** — keys live only in `x-api-key`/`authorization` headers; every log line on those paths carries name/model/url/error only (verified across `net/anthropic.zig`, `net/openai.zig`, `provider_boot.zig`, `trace.zig`). (Finding 5's env-inheritance path is a *different* leak and stands.)
- **TLS verification disabled** — never touches `std.options.http_disable_tls`; system CA verified on (`std/http/Client.zig:1708-1722` in 0.16).
- **Malformed SSE / `[DONE]` / CRLF / multi-line data crashes** — all handled per WHATWG (`sse.zig:80-125`); assemblers skip malformed events and stay usable.
- **Policy `matches()` over-match** (`""`, `*bash` prefix forms) — empty never matches (len-0 guard, `policy.zig:82`); `*bash` is a literal and matches nothing; first-match-wins is a safe linear scan. (The function-namespace star match, L8, stands.)
- **tool_result ↔ tool_use id mismatch corrupting the conversation** — ids pass through verbatim in block order; dispatch is one blocking call per block (`worker/turn.zig`).
- **Trim/filter corrupting UTF-8 or JSON envelopes** — boundary walks forward+backward verified with an exhaustive limit-sweep test; envelope unwrap/re-wrap round-trips pinned per tool shape; `truncateJsonArray` terminates.
- **Unbounded kernel inbox memory** — the inbox is a bounded ring; producers block (`actor/inbox.zig:34`).
- **Mission resume identity confusion / corrupt state load** — id mismatch → `MalformedRequest`; garbage `mission.json` → `Corrupt`, start refused (`mission.zig:399-402`, tested).
- **MCP gateway tool injection** — static 9-tool allowlist; unknown → `-32602` without a bus call (`mcp/gateway.zig:51-144`); spawn argv exec'd directly, never through a shell (`mcp/transport.zig:87`).
- **Vault path traversal via project names** — `validProjectName`/`projectExists` reject `/`, `\`, NUL, `.`, `..` (`tessera_continuity.zig:194-201`). (Content injection into SESSIONS.md, L5, stands.)
- **Infinite replan loop in the mission FSM** — `max_role_turns` bounds every replan cycle including gate-deny→planning; the gate call itself is exempt and correctly so (`mission.zig:433`, `:653`).
- **`now_ms + timeout` integer overflow** — poster-stamped wall clocks bounded far below i64 max.
- **Approval timeout resurrecting a denied ask** — `in_time ands away` late resolves (`approval.zig:124`). (The approver-side reporting race, L3, stands.)
