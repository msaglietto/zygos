//! Shared kernel identity types. I/O-free so catalog/invocation/trigger can
//! share WorkerId/Uuid without importing each other (module independence rule,
//! AGENTS.md). Wire ids are UUID text; the kernel works in bytes.

/// Worker connection identity: UUID bytes assigned at connect.
pub const WorkerId = [16]u8;

/// Owner of built-in functions; never removed by any disconnect path.
pub const KERNEL_WORKER: WorkerId = [_]u8{0} ** 16;

/// Invocation correlation id (UUID bytes).
pub const Uuid = [16]u8;
