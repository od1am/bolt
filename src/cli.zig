const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("config.zig");
const Config = config_mod.Config;

pub fn parseArgs(allocator: Allocator) !Config {
    var config = config_mod.default_config;

    // Allocate strings
    config.torrent_path = try allocator.dupe(u8, config.torrent_path);
    config.output_dir = try allocator.dupe(u8, config.output_dir);
    config.peer_id = config_mod.generatePeerId();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "-t")) {
            allocator.free(config.torrent_path);
            config.torrent_path = try allocator.dupe(u8, args.next() orelse return error.MissingTorrentPath);
        } else if (std.mem.eql(u8, arg, "-o")) {
            allocator.free(config.output_dir);
            config.output_dir = try allocator.dupe(u8, args.next() orelse return error.MissingOutputDir);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }

    if (config.torrent_path.len == 0) return error.MissingTorrentPath;
    return config;
}

fn printHelp() void {
    std.debug.print(
        \\BitTorrent Client Usage:
        \\  -h          Show this help message
        \\  -t PATH     Path to .torrent file (required)
        \\  -o DIR      Output directory [default: .]
        \\
    , .{});
}
