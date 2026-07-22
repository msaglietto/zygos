//! Zygos public module root. Re-exports kernel modules for consumers and is the
//! root of the library's test binary. Importing `kernel/*` here makes their test
//! blocks part of `zig build test`.

const std = @import("std");

pub const protocol = @import("kernel/protocol.zig");
pub const actor = @import("kernel/actor.zig");
pub const inproc = @import("kernel/inproc.zig");
pub const net = @import("net/ws.zig");
pub const ticker = @import("net/ticker.zig");
pub const stream_guard = @import("net/stream_guard.zig");
pub const net_anthropic = @import("net/anthropic.zig");
pub const provider_anthropic = @import("net/provider_anthropic.zig");
pub const net_openai = @import("net/openai.zig");
pub const provider_openai = @import("net/provider_openai.zig");
pub const provider_boot = @import("net/provider_boot.zig");
pub const web_tools = @import("net/web_tools.zig");
pub const provider_fake = @import("worker/provider_fake.zig");
pub const turn = @import("worker/turn.zig");
pub const trace = @import("worker/trace.zig");
pub const trace_event = @import("worker/trace_event.zig");
pub const stream_tap = @import("worker/stream_tap.zig");
pub const mission = @import("worker/mission.zig");
pub const mission_store = @import("worker/mission_store.zig");
pub const mission_boot = @import("worker/mission_boot.zig");
pub const brief = @import("worker/brief.zig");
pub const context = @import("worker/context.zig");
pub const context_substrate = @import("worker/context_substrate.zig");
pub const context_conformance = @import("worker/context_conformance.zig");
pub const context_recall = @import("worker/context_recall.zig");
pub const context_thread = @import("worker/context_thread.zig");
pub const control = @import("worker/control.zig");
pub const playbook = @import("worker/playbook.zig");
pub const tessera_vault = @import("worker/tessera/vault.zig");
pub const tessera_session_writer = @import("worker/tessera/session_writer.zig");
pub const tessera_orient = @import("worker/tessera_orient.zig");
pub const tessera_continuity = @import("worker/tessera_continuity.zig");
pub const tessera_capture = @import("worker/tessera_capture.zig");
pub const tessera_undo = @import("worker/tessera_undo.zig");
pub const mcp_gateway = @import("worker/mcp/gateway.zig");
pub const mcp_client = @import("worker/mcp/client.zig");
pub const policy = @import("worker/policy.zig");
pub const approval = @import("worker/approval.zig");
pub const router = @import("worker/router.zig");
pub const budget = @import("worker/budget.zig");
pub const trim = @import("worker/trim.zig");
pub const openai = @import("worker/openai.zig");
pub const sse = @import("worker/sse.zig");
pub const tools = @import("worker/tools.zig");
pub const tools_ops = @import("worker/tools_ops.zig");
pub const anthropic = @import("worker/anthropic.zig");
pub const assembler = @import("worker/assembler.zig");
pub const providers_catalog = @import("config/providers.zig");
pub const tui = @import("tui/tui.zig");
pub const types = @import("kernel/types.zig");
pub const sync = @import("kernel/sync.zig");
pub const catalog = @import("kernel/catalog.zig");
pub const channel = @import("kernel/channel.zig");
pub const invocation = @import("kernel/invocation.zig");
pub const trigger = @import("kernel/trigger.zig");

test {
    // Pull every declaration (and thus every kernel module's test blocks) into the
    // root test binary so `zig build test` discovers them.
    std.testing.refAllDecls(@This());
}
