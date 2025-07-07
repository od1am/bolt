const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

pub fn parseArgs(allocator: Allocator) !config.Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for help flag first
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("Bolt BitTorrent Client\n\n", .{});
            std.debug.print("Usage: {s} <torrent_file> [options]\n", .{args[0]});
            std.debug.print("Options:\n", .{});
            std.debug.print("  --output-dir <dir>    Output directory (default: current directory)\n", .{});
            std.debug.print("  --port <port>         Listen port (default: 6881)\n", .{});
            std.debug.print("  --max-peers <num>     Maximum number of peers (default: 50)\n", .{});
            std.debug.print("  --help                Show this help message\n", .{});
            return error.HelpRequested;
        }
    }

    if (args.len < 2) {
        std.debug.print("Usage: {s} <torrent_file> [options]\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --output-dir <dir>    Output directory (default: current directory)\n", .{});
        std.debug.print("  --port <port>         Listen port (default: 6881)\n", .{});
        std.debug.print("  --max-peers <num>     Maximum number of peers (default: 50)\n", .{});
        std.debug.print("  --help                Show this help message\n", .{});
        return error.InvalidArguments;
    }

    var conf = config.default_config;
    conf.torrent_path = try allocator.dupe(u8, args[1]);
    conf.output_dir = try allocator.dupe(u8, ".");
    conf.peer_id = config.generatePeerId();

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--output-dir")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --output-dir requires a directory argument\n", .{});
                return error.InvalidArguments;
            }
            allocator.free(conf.output_dir);
            conf.output_dir = try allocator.dupe(u8, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --port requires a port number\n", .{});
                return error.InvalidArguments;
            }
            conf.listen_port = std.fmt.parseInt(u16, args[i + 1], 10) catch |err| {
                std.debug.print("Error: Invalid port number '{s}': {}\n", .{ args[i + 1], err });
                return error.InvalidArguments;
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--max-peers")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --max-peers requires a number\n", .{});
                return error.InvalidArguments;
            }
            conf.max_peers = std.fmt.parseInt(u8, args[i + 1], 10) catch |err| {
                std.debug.print("Error: Invalid max peers number '{s}': {}\n", .{ args[i + 1], err });
                return error.InvalidArguments;
            };
            i += 1;
        } else {
            std.debug.print("Error: Unknown option '{s}'\n", .{args[i]});
            std.debug.print("Use --help for usage information\n", .{});
            return error.InvalidArguments;
        }
    }

    return conf;
}

const testing = std.testing;

test "parseArgs with help flag" {
    const cfg = @import("config.zig").default_config;
    try testing.expect(cfg.listen_port == 6881);
    try testing.expect(cfg.max_peers == 50);
}

test "config generation" {
    const config_mod = @import("config.zig");
    const id1 = config_mod.generatePeerId();
    const id2 = config_mod.generatePeerId();
    try testing.expect(id1.len == 20);
    try testing.expect(id2.len == 20);
    try testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "default config values" {
    const cfg = @import("config.zig").default_config;
    try testing.expect(cfg.listen_port == 6881);
    try testing.expect(cfg.max_peers == 50);
}
