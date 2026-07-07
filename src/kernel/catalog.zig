//! Zygos function & service registry (S2). Implements GOAL.md criterion S2
//! and PROTOCOL.md semantics 2 (last registration wins) and 3 (CAS-gated
//! teardown). The catalog is owned by the kernel actor and touched from
//! exactly one thread — no mutexes, no atomics (decision Z-02; see
//! docs/specs/catalog.md "Threading model").
//!
//! This module knows nothing of sockets or wire parsing; it must not import
//! protocol.zig. Only types.zig is shared (WorkerId / KERNEL_WORKER).

const std = @import("std");
const types = @import("types.zig");

// ---------------------------------------------------------------------------
// Re-exported identity types (module independence rule, AGENTS.md)
// ---------------------------------------------------------------------------

pub const WorkerId = types.WorkerId;
pub const KERNEL_WORKER = types.KERNEL_WORKER;

// ---------------------------------------------------------------------------
// Handler types
// ---------------------------------------------------------------------------

/// Errors a built-in function may return when invoked in-process.
pub const BuiltinError = error{ OutOfMemory, Failed };

/// Provisional signature for in-process built-in functions. actor.zig will
/// define the real dispatch contract; M0 stores the pointer for routing only.
pub const BuiltinFn = fn (gpa: std.mem.Allocator, request_json: []const u8) BuiltinError![]u8;

/// Invocation reference for an external-HTTP handler. M0 stores this for
/// discovery only — it never dispatches HTTP. All three slices are owned
/// copies (duped on register, freed on remove/deinit).
pub const HttpRef = struct {
    url: []const u8,
    method: []const u8,
    /// Full JSON text of the invocation ref (unparsed).
    raw: []const u8,
};

/// How a registered function is dispatched. The union tag distinguishes the
/// kind so the catalog needs only one owner map (unlike iii's two).
pub const Handler = union(enum) {
    /// Dispatch: send invokefunction to this connection.
    worker: WorkerId,
    /// Dispatch: call in-process on the kernel side.
    builtin: *const BuiltinFn,
    /// Dispatch: HTTP call (M0: store only, no dispatch).
    external_http: HttpRef,
};

// ---------------------------------------------------------------------------
// Entry types
// ---------------------------------------------------------------------------

/// A catalogued function. All `[]const u8` fields are owned copies (duped on
/// insert, freed on overwrite/remove/deinit). Schemas stay raw JSON text —
/// the catalog never interprets them.
pub const Entry = struct {
    handler: Handler,
    description: []const u8,
    request_format: ?[]const u8 = null,
    response_format: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
};

/// Input to `register()`: same shape as `Entry` but all slices are **borrowed**
/// from the caller for the duration of the call only. `register()` dupes
/// everything it stores.
pub const EntryInit = struct {
    handler: Handler,
    description: []const u8,
    request_format: ?[]const u8 = null,
    response_format: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
};

/// Return value of `register()`: `.new` for a fresh id, `.overwrote` when an
/// existing id was replaced (caller may warn-log).
pub const RegisterResult = enum { new, overwrote };

/// One row surfaced by `iterator()`.
pub const EntryView = struct {
    id: []const u8,
    owner: WorkerId,
    entry: *const Entry,
};

// ---------------------------------------------------------------------------
// Iterator
// ---------------------------------------------------------------------------

/// Wraps the underlying map iterator, exposing id, owner, and a const pointer
/// to the entry. For discovery listings (`engine::functions::list`, later).
pub const Iterator = struct {
    inner: std.StringHashMap(EntryRecord).Iterator,

    pub fn next(self: *Iterator) ?EntryView {
        const kv = self.inner.next() orelse return null;
        return .{
            .id = kv.key_ptr.*,
            .owner = kv.value_ptr.owner,
            .entry = &kv.value_ptr.entry,
        };
    }
};

// ---------------------------------------------------------------------------
// Internal records
// ---------------------------------------------------------------------------

/// Stored alongside the entry: one owner per id. iii keeps two owner maps;
/// Zygos keeps one — the Handler union already distinguishes the kind.
const EntryRecord = struct {
    entry: Entry,
    owner: WorkerId,
};

const ServiceRecord = struct {
    entry: ServiceEntry,
    owner: WorkerId,
};

// ---------------------------------------------------------------------------
// Owner-index helpers (shared by Catalog and ServiceRegistry)
//
// The per-worker id index enables O(entries owned) disconnect cleanup without
// rescanning all entries. Inner map keys alias the owned id strings stored as
// keys in `entries` (not separate copies). Empty sets are pruned on removal so
// the index stays tight.
// ---------------------------------------------------------------------------

/// Type alias so the helper signatures stay readable.
const OwnerIndex = std.AutoHashMap(WorkerId, std.StringHashMap(void));

fn ownerIndexAdd(
    owners: *OwnerIndex,
    gpa: std.mem.Allocator,
    owner_id: WorkerId,
    owned_id: []const u8,
) error{OutOfMemory}!void {
    const gop = try owners.getOrPut(owner_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = std.StringHashMap(void).init(gpa);
    }
    try gop.value_ptr.put(owned_id, {});
}

fn ownerIndexRemove(owners: *OwnerIndex, owner_id: WorkerId, id: []const u8) void {
    const id_set = owners.getPtr(owner_id) orelse return;
    _ = id_set.remove(id);
    if (id_set.count() == 0) {
        if (owners.fetchRemove(owner_id)) |removed| {
            var set = removed.value;
            set.deinit();
        }
    }
}

/// Free every inner id-set, then the outer map. Called from deinit.
fn ownerIndexDeinit(owners: *OwnerIndex) void {
    var it = owners.iterator();
    while (it.next()) |kv| {
        kv.value_ptr.deinit();
    }
    owners.deinit();
}

// ---------------------------------------------------------------------------
// Entry memory helpers
// ---------------------------------------------------------------------------

fn freeHandler(gpa: std.mem.Allocator, handler: Handler) void {
    switch (handler) {
        .worker, .builtin => {},
        .external_http => |ref| {
            gpa.free(ref.url);
            gpa.free(ref.method);
            gpa.free(ref.raw);
        },
    }
}

fn freeEntry(gpa: std.mem.Allocator, entry: Entry) void {
    freeHandler(gpa, entry.handler);
    gpa.free(entry.description);
    if (entry.request_format) |s| gpa.free(s);
    if (entry.response_format) |s| gpa.free(s);
    if (entry.metadata) |s| gpa.free(s);
}

/// Deep-copy every owned slice from the borrowed `EntryInit` into a new `Entry`.
/// On error, any partially allocated fields are freed.
fn dupeEntry(gpa: std.mem.Allocator, init: EntryInit) error{OutOfMemory}!Entry {
    const description = try gpa.dupe(u8, init.description);
    errdefer gpa.free(description);

    const handler: Handler = switch (init.handler) {
        .worker => |w| .{ .worker = w },
        .builtin => |b| .{ .builtin = b },
        .external_http => |ref| blk: {
            const url = try gpa.dupe(u8, ref.url);
            errdefer gpa.free(url);
            const method = try gpa.dupe(u8, ref.method);
            errdefer gpa.free(method);
            const raw = try gpa.dupe(u8, ref.raw);
            // Inner errdefers are scoped to this block and cancel on break.
            break :blk .{ .external_http = .{ .url = url, .method = method, .raw = raw } };
        },
    };
    errdefer freeHandler(gpa, handler);

    const request_format = if (init.request_format) |s| try gpa.dupe(u8, s) else null;
    errdefer if (request_format) |s| gpa.free(s);

    const response_format = if (init.response_format) |s| try gpa.dupe(u8, s) else null;
    errdefer if (response_format) |s| gpa.free(s);

    const metadata = if (init.metadata) |s| try gpa.dupe(u8, s) else null;

    return .{
        .handler = handler,
        .description = description,
        .request_format = request_format,
        .response_format = response_format,
        .metadata = metadata,
    };
}

// ---------------------------------------------------------------------------
// Service entry memory helpers
// ---------------------------------------------------------------------------

fn freeServiceEntry(gpa: std.mem.Allocator, entry: ServiceEntry) void {
    gpa.free(entry.name);
    gpa.free(entry.description);
    if (entry.parent_service_id) |s| gpa.free(s);
}

fn dupeServiceEntry(gpa: std.mem.Allocator, init: ServiceEntryInit) error{OutOfMemory}!ServiceEntry {
    const name = try gpa.dupe(u8, init.name);
    errdefer gpa.free(name);

    const description = try gpa.dupe(u8, init.description);
    errdefer gpa.free(description);

    const parent_service_id = if (init.parent_service_id) |s| try gpa.dupe(u8, s) else null;

    return .{
        .name = name,
        .description = description,
        .parent_service_id = parent_service_id,
    };
}

// ---------------------------------------------------------------------------
// Catalog
// ---------------------------------------------------------------------------

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    entries: std.StringHashMap(EntryRecord),
    owners: OwnerIndex,

    pub fn init(gpa: std.mem.Allocator) Catalog {
        return .{
            .gpa = gpa,
            .entries = std.StringHashMap(EntryRecord).init(gpa),
            .owners = OwnerIndex.init(gpa),
        };
    }

    pub fn deinit(self: *Catalog) void {
        // Free every owned id key + entry payload.
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            freeEntry(self.gpa, kv.value_ptr.entry);
            self.gpa.free(kv.key_ptr.*);
        }
        self.entries.deinit();
        ownerIndexDeinit(&self.owners);
    }

    /// Last registration wins: an existing id is overwritten (old entry freed,
    /// owner replaced) and `.overwrote` is returned so the caller can warn-log.
    pub fn register(
        self: *Catalog,
        id: []const u8,
        owner_id: WorkerId,
        init_entry: EntryInit,
    ) error{OutOfMemory}!RegisterResult {
        if (self.entries.getPtr(id)) |existing| {
            const old_owner = existing.owner;

            // Dupe the new entry *before* freeing the old one so a failure
            // leaves the catalog untouched.
            const new_entry = try dupeEntry(self.gpa, init_entry);
            errdefer freeEntry(self.gpa, new_entry);

            // Swap owner-index membership. Add to new first; if that fails the
            // old index is still intact (clean rollback).
            if (!std.mem.eql(u8, &old_owner, &owner_id)) {
                const stored_key = self.entries.getKey(id).?;
                try ownerIndexAdd(&self.owners, self.gpa, owner_id, stored_key);
                ownerIndexRemove(&self.owners, old_owner, id);
            }

            freeEntry(self.gpa, existing.entry);
            existing.entry = new_entry;
            existing.owner = owner_id;
            return .overwrote;
        }

        // New id.
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);

        const new_entry = try dupeEntry(self.gpa, init_entry);
        errdefer freeEntry(self.gpa, new_entry);

        try self.entries.put(owned_id, .{ .entry = new_entry, .owner = owner_id });
        errdefer _ = self.entries.fetchRemove(owned_id);

        try ownerIndexAdd(&self.owners, self.gpa, owner_id, owned_id);
        return .new;
    }

    /// Explicit unregisterfunction from a worker. Removes ONLY if `requester`
    /// is the current owner; otherwise a no-op returning false (warn-log at
    /// the call site). A worker must never evict another worker's registration.
    pub fn unregister(self: *Catalog, id: []const u8, requester: WorkerId) bool {
        return self.releaseIfOwner(id, requester);
    }

    pub fn get(self: *const Catalog, id: []const u8) ?*const Entry {
        const record = self.entries.getPtr(id) orelse return null;
        return &record.entry;
    }

    pub fn owner(self: *const Catalog, id: []const u8) ?WorkerId {
        const record = self.entries.getPtr(id) orelse return null;
        return record.owner;
    }

    /// Disconnect cleanup for one id: remove only if `departing` still owns it.
    /// Returns true if removed. This is the CAS-gated teardown (PROTOCOL.md §3).
    pub fn releaseIfOwner(self: *Catalog, id: []const u8, departing: WorkerId) bool {
        const record = self.entries.getPtr(id) orelse return false;
        if (!std.mem.eql(u8, &record.owner, &departing)) return false;

        ownerIndexRemove(&self.owners, departing, id);

        const removed = self.entries.fetchRemove(id) orelse return false;
        freeEntry(self.gpa, removed.value.entry);
        self.gpa.free(removed.key);
        return true;
    }

    /// Disconnect cleanup for a whole connection: release every id owned by
    /// `departing`. Returns count removed. O(entries owned) via the per-worker
    /// id index — never a rescan of all entries.
    pub fn removeAllOwnedBy(self: *Catalog, departing: WorkerId) usize {
        // Steal the owner's id-set out of the index (O(1) lookup).
        const stolen = self.owners.fetchRemove(departing) orelse return 0;
        var id_set = stolen.value;
        defer id_set.deinit();

        var removed_count: usize = 0;
        var it = id_set.iterator();
        while (it.next()) |kv| {
            // kv.key_ptr.* aliases the owned id string in `entries`.
            if (self.entries.fetchRemove(kv.key_ptr.*)) |removed| {
                freeEntry(self.gpa, removed.value.entry);
                self.gpa.free(removed.key);
                removed_count += 1;
            }
        }
        return removed_count;
    }

    pub fn count(self: *const Catalog) usize {
        return self.entries.count();
    }

    pub fn iterator(self: *const Catalog) Iterator {
        return .{ .inner = self.entries.iterator() };
    }
};

// ---------------------------------------------------------------------------
// Service registry (minimal, same file)
// ---------------------------------------------------------------------------

pub const ServiceEntry = struct {
    name: []const u8,
    description: []const u8,
    parent_service_id: ?[]const u8 = null,
};

pub const ServiceEntryInit = struct {
    name: []const u8,
    description: []const u8,
    parent_service_id: ?[]const u8 = null,
};

pub const ServiceRegistry = struct {
    gpa: std.mem.Allocator,
    entries: std.StringHashMap(ServiceRecord),
    owners: OwnerIndex,

    pub fn init(gpa: std.mem.Allocator) ServiceRegistry {
        return .{
            .gpa = gpa,
            .entries = std.StringHashMap(ServiceRecord).init(gpa),
            .owners = OwnerIndex.init(gpa),
        };
    }

    pub fn deinit(self: *ServiceRegistry) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            freeServiceEntry(self.gpa, kv.value_ptr.entry);
            self.gpa.free(kv.key_ptr.*);
        }
        self.entries.deinit();
        ownerIndexDeinit(&self.owners);
    }

    pub fn register(
        self: *ServiceRegistry,
        id: []const u8,
        owner_id: WorkerId,
        init_entry: ServiceEntryInit,
    ) error{OutOfMemory}!RegisterResult {
        if (self.entries.getPtr(id)) |existing| {
            const old_owner = existing.owner;

            const new_entry = try dupeServiceEntry(self.gpa, init_entry);
            errdefer freeServiceEntry(self.gpa, new_entry);

            if (!std.mem.eql(u8, &old_owner, &owner_id)) {
                const stored_key = self.entries.getKey(id).?;
                try ownerIndexAdd(&self.owners, self.gpa, owner_id, stored_key);
                ownerIndexRemove(&self.owners, old_owner, id);
            }

            freeServiceEntry(self.gpa, existing.entry);
            existing.entry = new_entry;
            existing.owner = owner_id;
            return .overwrote;
        }

        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);

        const new_entry = try dupeServiceEntry(self.gpa, init_entry);
        errdefer freeServiceEntry(self.gpa, new_entry);

        try self.entries.put(owned_id, .{ .entry = new_entry, .owner = owner_id });
        errdefer _ = self.entries.fetchRemove(owned_id);

        try ownerIndexAdd(&self.owners, self.gpa, owner_id, owned_id);
        return .new;
    }

    pub fn unregister(self: *ServiceRegistry, id: []const u8, requester: WorkerId) bool {
        return self.releaseIfOwner(id, requester);
    }

    pub fn get(self: *const ServiceRegistry, id: []const u8) ?*const ServiceEntry {
        const record = self.entries.getPtr(id) orelse return null;
        return &record.entry;
    }

    pub fn owner(self: *const ServiceRegistry, id: []const u8) ?WorkerId {
        const record = self.entries.getPtr(id) orelse return null;
        return record.owner;
    }

    pub fn releaseIfOwner(self: *ServiceRegistry, id: []const u8, departing: WorkerId) bool {
        const record = self.entries.getPtr(id) orelse return false;
        if (!std.mem.eql(u8, &record.owner, &departing)) return false;

        ownerIndexRemove(&self.owners, departing, id);

        const removed = self.entries.fetchRemove(id) orelse return false;
        freeServiceEntry(self.gpa, removed.value.entry);
        self.gpa.free(removed.key);
        return true;
    }

    pub fn removeAllOwnedBy(self: *ServiceRegistry, departing: WorkerId) usize {
        const stolen = self.owners.fetchRemove(departing) orelse return 0;
        var id_set = stolen.value;
        defer id_set.deinit();

        var removed_count: usize = 0;
        var it = id_set.iterator();
        while (it.next()) |kv| {
            if (self.entries.fetchRemove(kv.key_ptr.*)) |removed| {
                freeServiceEntry(self.gpa, removed.value.entry);
                self.gpa.free(removed.key);
                removed_count += 1;
            }
        }
        return removed_count;
    }

    pub fn count(self: *const ServiceRegistry) usize {
        return self.entries.count();
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Build a WorkerId filled with a repeating byte.
fn makeWorker(comptime byte: u8) WorkerId {
    return [_]u8{byte} ** 16;
}

/// Dummy built-in function for handler tests.
fn dummyBuiltin(_: std.mem.Allocator, _: []const u8) BuiltinError![]u8 {
    return error.Failed;
}

const worker_a = makeWorker(0xAA);
const worker_a2 = makeWorker(0xBB);
const worker_b = makeWorker(0x11);

// 1 -----------------------------------------------------------------------

test "register new id returns .new; get returns the entry" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    const result = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "function f",
        .request_format = "{\"type\":\"object\"}",
        .response_format = null,
        .metadata = null,
    });
    try testing.expect(result == .new);

    const e = cat.get("f") orelse return error.TestUnexpectedNull;
    try testing.expect(e.handler == .worker);
    try testing.expectEqualStrings("function f", e.description);
    try testing.expectEqualStrings("{\"type\":\"object\"}", e.request_format.?);
    try testing.expect(e.response_format == null);
    try testing.expect(e.metadata == null);

    try testing.expectEqual(worker_a, cat.owner("f").?);
    try testing.expectEqual(@as(usize, 1), cat.count());
}

// 2 -----------------------------------------------------------------------

test "re-register same id returns .overwrote; handler and owner replaced" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    _ = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "first",
    });
    const result = try cat.register("f", worker_a2, .{
        .handler = .{ .worker = worker_a2 },
        .description = "second",
    });
    try testing.expect(result == .overwrote);

    const e = cat.get("f") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("second", e.description);
    try testing.expectEqual(worker_a2, e.handler.worker);
    try testing.expectEqual(worker_a2, cat.owner("f").?);
}

// 3 -----------------------------------------------------------------------

test "overwrite frees the old entry (no leak under overwrite loop)" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const desc_buf = try std.fmt.allocPrint(testing.allocator, "desc-{d}", .{i});
        defer testing.allocator.free(desc_buf);
        _ = try cat.register("f", worker_a, .{
            .handler = .{ .worker = worker_a },
            .description = desc_buf,
        });
    }
    // Under testing.allocator a leak would be reported at deinit.
    try testing.expectEqual(@as(usize, 1), cat.count());
}

// 4 -----------------------------------------------------------------------

test "unregister by owner removes and returns true" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    _ = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f",
    });
    try testing.expect(cat.unregister("f", worker_a));
    try testing.expect(cat.get("f") == null);
    try testing.expect(cat.owner("f") == null);
    try testing.expectEqual(@as(usize, 0), cat.count());
}

// 5 -----------------------------------------------------------------------

test "unregister by non-owner is a no-op returning false; entry intact" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    _ = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f",
    });
    try testing.expect(!cat.unregister("f", worker_b));
    // Entry survives.
    const e = cat.get("f") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("f", e.description);
    try testing.expectEqual(worker_a, cat.owner("f").?);
    try testing.expectEqual(@as(usize, 1), cat.count());
}

// 6 -----------------------------------------------------------------------

test "releaseIfOwner removes when departing worker still owns the id" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    _ = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f",
    });
    try testing.expect(cat.releaseIfOwner("f", worker_a));
    try testing.expect(cat.get("f") == null);
    try testing.expectEqual(@as(usize, 0), cat.count());
}

// 7 -----------------------------------------------------------------------

test "releaseIfOwner no-ops when owner differs" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    // A registers f, then A' (new WorkerId) re-registers f.
    _ = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f",
    });
    _ = try cat.register("f", worker_a2, .{
        .handler = .{ .worker = worker_a2 },
        .description = "f-v2",
    });

    // A's stale disconnect cleanup arrives — must NOT evict A'.
    try testing.expect(!cat.releaseIfOwner("f", worker_a));

    // Entry survives, owned by A'.
    try testing.expect(cat.get("f") != null);
    try testing.expectEqual(worker_a2, cat.owner("f").?);
    try testing.expectEqual(@as(usize, 1), cat.count());
}

// 8 -----------------------------------------------------------------------

test "reconnect churn end-to-end" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    // A registers f and g.
    _ = try cat.register("f", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f",
    });
    _ = try cat.register("g", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "g",
    });

    // A' re-registers f (last-wins overwrites A's f).
    _ = try cat.register("f", worker_a2, .{
        .handler = .{ .worker = worker_a2 },
        .description = "f-v2",
    });

    // A disconnects — g should be removed, f survives owned by A'.
    const removed = cat.removeAllOwnedBy(worker_a);
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(cat.get("g") == null);
    try testing.expect(cat.get("f") != null);
    try testing.expectEqual(worker_a2, cat.owner("f").?);
    try testing.expectEqual(@as(usize, 1), cat.count());
}

// 9 -----------------------------------------------------------------------

test "removeAllOwnedBy removes only the departing worker's entries" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    // Worker A owns f1, f2. Worker B owns f3, f4. Disjoint sets.
    _ = try cat.register("f1", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f1",
    });
    _ = try cat.register("f2", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "f2",
    });
    _ = try cat.register("f3", worker_b, .{
        .handler = .{ .worker = worker_b },
        .description = "f3",
    });
    _ = try cat.register("f4", worker_b, .{
        .handler = .{ .worker = worker_b },
        .description = "f4",
    });

    const removed = cat.removeAllOwnedBy(worker_a);
    try testing.expectEqual(@as(usize, 2), removed);

    // A's entries gone.
    try testing.expect(cat.get("f1") == null);
    try testing.expect(cat.get("f2") == null);
    // B's entries intact.
    try testing.expect(cat.get("f3") != null);
    try testing.expect(cat.get("f4") != null);
    try testing.expectEqual(@as(usize, 2), cat.count());
}

// 10 ----------------------------------------------------------------------

test "builtin owned by KERNEL_WORKER survives removeAllOwnedBy of any worker" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    const dummy_fn: *const BuiltinFn = &dummyBuiltin;

    _ = try cat.register("sys.echo", KERNEL_WORKER, .{
        .handler = .{ .builtin = dummy_fn },
        .description = "built-in echo",
    });
    _ = try cat.register("user.fn", worker_a, .{
        .handler = .{ .worker = worker_a },
        .description = "user function",
    });

    // Worker A disconnects — user.fn removed, sys.echo survives.
    const removed = cat.removeAllOwnedBy(worker_a);
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expect(cat.get("user.fn") == null);

    // Built-in still there, still owned by KERNEL_WORKER.
    const e = cat.get("sys.echo") orelse return error.TestUnexpectedNull;
    try testing.expect(e.handler == .builtin);
    try testing.expectEqual(KERNEL_WORKER, cat.owner("sys.echo").?);
    try testing.expectEqual(@as(usize, 1), cat.count());
}

// 11 ----------------------------------------------------------------------

test "get/owner on unknown id returns null" {
    var cat = Catalog.init(testing.allocator);
    defer cat.deinit();

    try testing.expect(cat.get("nope") == null);
    try testing.expect(cat.owner("nope") == null);
    try testing.expectEqual(@as(usize, 0), cat.count());
}

// 12 ----------------------------------------------------------------------

test "service registry: register, duplicate overwrite, releaseIfOwner" {
    var reg = ServiceRegistry.init(testing.allocator);
    defer reg.deinit();

    // Register new.
    const r1 = try reg.register("svc-1", worker_a, .{
        .name = "orders",
        .description = "order service",
        .parent_service_id = null,
    });
    try testing.expect(r1 == .new);
    try testing.expectEqual(@as(usize, 1), reg.count());

    const se = reg.get("svc-1") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("orders", se.name);
    try testing.expectEqualStrings("order service", se.description);
    try testing.expectEqual(worker_a, reg.owner("svc-1").?);

    // Duplicate overwrite (same id, new owner + new data).
    const r2 = try reg.register("svc-1", worker_a2, .{
        .name = "orders-v2",
        .description = "order service v2",
        .parent_service_id = "root",
    });
    try testing.expect(r2 == .overwrote);

    const se2 = reg.get("svc-1") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("orders-v2", se2.name);
    try testing.expectEqualStrings("root", se2.parent_service_id.?);
    try testing.expectEqual(worker_a2, reg.owner("svc-1").?);

    // releaseIfOwner — wrong owner no-ops.
    try testing.expect(!reg.releaseIfOwner("svc-1", worker_a));
    try testing.expect(reg.get("svc-1") != null);

    // releaseIfOwner — correct owner removes.
    try testing.expect(reg.releaseIfOwner("svc-1", worker_a2));
    try testing.expect(reg.get("svc-1") == null);
    try testing.expectEqual(@as(usize, 0), reg.count());
}
