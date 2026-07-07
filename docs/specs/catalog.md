# Spec: `src/kernel/catalog.zig` — function & service registry (S2)

Implements GOAL.md criterion **S2** and PROTOCOL.md semantics **2 (last
registration wins)** and **3 (CAS-gated teardown)**. Read those first.

## Threading model — read this before the data structures

The catalog is **owned by the kernel actor** and touched from exactly one
thread. No mutexes, no atomics, no lock-free structures inside this module —
plain `std.StringHashMap` etc. This is a deliberate divergence from iii's
`DashMap` design (decision Z-02).

The concurrency hazard iii guards against does **not** disappear, it changes
shape: connection reader threads post commands to the kernel inbox, and a
stale connection's disconnect-cleanup command can be *ordered after* a fresh
reconnect's register command for the same function id. The owner check below
is what makes that interleaving safe. Same invariant as iii, enforced by
command ordering instead of concurrent maps.

## Data model

```zig
pub const WorkerId = [16]u8;                    // UUID bytes
pub const KERNEL_WORKER: WorkerId = [_]u8{0} ** 16;  // owner of built-in functions

pub const Handler = union(enum) {
    worker: WorkerId,               // dispatch: send invokefunction to this connection
    builtin: *const BuiltinFn,      // dispatch: call in-process on the kernel side
    external_http: HttpRef,         // dispatch: HTTP call (M0: store only, no dispatch)
};

pub const Entry = struct {
    handler: Handler,
    description: []const u8,        // owned copy
    request_format: ?[]const u8,    // owned copy of RAW JSON text, not parsed
    response_format: ?[]const u8,   // ditto
    metadata: ?[]const u8,          // ditto
};
```

Notes:
- **Schemas stay raw JSON text.** The catalog never interprets them; it only
  serves them back for discovery (`engine::functions::list`, later). Storing
  parsed `std.json.Value` trees buys nothing and complicates ownership.
- **One owner record per id**, `owner: WorkerId` stored alongside the entry.
  iii keeps two owner maps (WS-routed vs external-HTTP); Zygos keeps one —
  the `Handler` union already distinguishes the kind, and the release
  semantics are identical. *Intentional, behavior-equivalent simplification.*
- **Built-ins are owned by `KERNEL_WORKER`** and therefore never removed by
  any disconnect path.

## Public API

```zig
pub const Catalog = struct {
    pub fn init(gpa: std.mem.Allocator) Catalog;
    pub fn deinit(self: *Catalog) void;

    /// Last registration wins: an existing id is overwritten (old entry freed,
    /// owner replaced) and .overwrote is returned so the caller can warn-log.
    pub fn register(self: *Catalog, id: []const u8, owner: WorkerId, entry: EntryInit)
        error{OutOfMemory}!enum { new, overwrote };

    /// Explicit unregisterfunction from a worker. Removes ONLY if `requester`
    /// is the current owner; otherwise a no-op returning false (warn-log at
    /// the call site). A worker must never evict another worker's registration.
    pub fn unregister(self: *Catalog, id: []const u8, requester: WorkerId) bool;

    pub fn get(self: *const Catalog, id: []const u8) ?*const Entry;
    pub fn owner(self: *const Catalog, id: []const u8) ?WorkerId;

    /// Disconnect cleanup for one id: remove only if `departing` still owns it.
    /// Returns true if removed. This is the CAS-gated teardown (PROTOCOL.md §3).
    pub fn releaseIfOwner(self: *Catalog, id: []const u8, departing: WorkerId) bool;

    /// Disconnect cleanup for a whole connection: releaseIfOwner over every id.
    /// Returns count removed. Must be O(entries owned), not O(all) re-scans per id
    /// — keep a per-worker id index if needed, but correctness first.
    pub fn removeAllOwnedBy(self: *Catalog, departing: WorkerId) usize;

    pub fn count(self: *const Catalog) usize;
    pub fn iterator(self: *const Catalog) Iterator;   // for discovery listings
};
```

Memory rules: `id`, `description`, and schema strings are **duped on insert
and freed on overwrite/remove/deinit**. The caller's slices are borrowed only
for the duration of `register`. Tests run under `std.testing.allocator` —
any leak is a test failure (see AGENTS.md).

## Service registry (minimal, same file)

`registerservice` frames need a home: `ServiceRegistry` mapping service id →
`{ name, description, parent_service_id }`, owned-copy semantics, same
owner/CAS rules as functions. Discovery-only in M0; keep it small.

## Test contract (write these RED first, named exactly)

1. `register new id returns .new; get returns the entry`
2. `re-register same id returns .overwrote; handler and owner replaced` — last-wins
3. `overwrite frees the old entry (no leak under overwrite loop)` — loop ≥100
   overwrites of one id under `std.testing.allocator`
4. `unregister by owner removes and returns true`
5. `unregister by non-owner is a no-op returning false; entry intact`
6. `releaseIfOwner removes when departing worker still owns the id`
7. `releaseIfOwner no-ops when owner differs` — **the S2 core**: A registers
   `f`, A' (new WorkerId) re-registers `f`, then A's release arrives → entry
   survives, `owner(f) == A'`, `get(f)` routes to A'
8. `reconnect churn end-to-end` — sequence: A registers f,g · A' registers f ·
   removeAllOwnedBy(A) → g removed, f survives owned by A', count correct
9. `removeAllOwnedBy removes only the departing worker's entries` — two live
   workers, disjoint id sets
10. `builtin owned by KERNEL_WORKER survives removeAllOwnedBy of any worker`
11. `get/owner on unknown id returns null`
12. `service registry: register, duplicate overwrite, releaseIfOwner` — same
    invariants as functions, one consolidated test

## Out of scope for this module

- Dispatch itself (actor.zig routes using `get().handler`).
- Session-prefixed id namespacing (`{prefix}::{id}`) — actor-level concern.
- `engine::functions::list` as a bus function — built-in worker, later.
- Any I/O, sockets, or protocol parsing — catalog must not import protocol.zig.
