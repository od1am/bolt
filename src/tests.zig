// Main test file that compiles and runs all tests
const std = @import("std");

// Import all modules that have tests
comptime {
    _ = @import("bencode.zig");
    _ = @import("cli_test.zig");
    _ = @import("torrent_test.zig");
}

pub fn main() !void {
    std.debug.print("Running all tests...\n", .{});
}
