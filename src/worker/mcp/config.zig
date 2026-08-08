//! `.mcp_servers` in zygos.zon (operator-owned, like routes). Reads the same
//! file as the router — unknown fields are ignored on both sides so the two
//! schemas coexist.

const std = @import("std");

pub const ServerSpec = struct {
    name: []const u8,
    argv: []const []const u8,
};

const McpConfigData = struct {
    mcp_servers: []const ServerSpec = &.{},
};

pub const McpConfig = struct {
    gpa: std.mem.Allocator,
    data: McpConfigData,

    pub fn parse(gpa: std.mem.Allocator, zon_text: [:0]const u8) error{ OutOfMemory, ParseZon }!McpConfig {
        return .{
            .gpa = gpa,
            .data = try std.zon.parse.fromSliceAlloc(McpConfigData, gpa, zon_text, null, .{
                .ignore_unknown_fields = true,
            }),
        };
    }

    pub fn deinit(self: *McpConfig) void {
        std.zon.parse.free(self.gpa, self.data);
        self.* = undefined;
    }

    pub fn servers(self: *const McpConfig) []const ServerSpec {
        return self.data.mcp_servers;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "McpConfig parses .mcp_servers and coexists with router fields; absent = empty" {
    const zon: [:0]const u8 =
        \\.{ .default = .{}, .routes = .{},
        \\   .mcp_servers = .{
        \\     .{ .name = "tavily", .argv = .{ "npx", "-y", "tavily-mcp" } },
        \\   } }
    ;
    var cfg = try McpConfig.parse(testing.allocator, zon);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.servers().len);
    try testing.expectEqualStrings("tavily", cfg.servers()[0].name);
    try testing.expectEqual(@as(usize, 3), cfg.servers()[0].argv.len);

    var empty = try McpConfig.parse(testing.allocator, ".{ .routes = .{} }");
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.servers().len);
}
