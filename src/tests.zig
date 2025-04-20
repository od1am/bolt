// Main test file that compiles and runs all tests
const std = @import("std");

// Import all modules that have tests
comptime {
    _ = @import("bencode.zig");
    _ = @import("cli_test.zig");
    _ = @import("torrent_test.zig");
    _ = @import("thread_pool_test_simple.zig");
    _ = @import("thread_pool.zig");
    _ = @import("metrics.zig");
}

pub fn main() !void {
    std.debug.print("Running all tests...\n", .{});
}
