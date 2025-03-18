const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("config.zig").Config;

pub fn parseArgs(allocator: Allocator) !Config {
    var config = Config{
        .torrent_path = try allocator.dupe(u8, ""),
        .output_dir = try allocator.dupe(u8, "."),
        .listen_port = 6881,
        .max_peers = 50,
        .peer_id = @import("config.zig").generatePeerId(),
    };

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--torrent")) {
            config.torrent_path = try allocator.dupe(u8, args.next() orelse return error.MissingTorrentPath);
        } else if (std.mem.eql(u8, arg, "--output")) {
            config.output_dir = try allocator.dupe(u8, args.next() orelse return error.MissingOutputDir);
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse return error.MissingPort;
            config.listen_port = std.fmt.parseUnsigned(u16, port_str, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--max-peers")) {
            const max_peers_str = args.next() orelse return error.MissingMaxPeers;
            config.max_peers = std.fmt.parseUnsigned(u8, max_peers_str, 10) catch return error.InvalidMaxPeers;
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
        \\  --help          Show this help message
        \\  --torrent PATH  Path to .torrent file (required)
        \\  --output DIR    Output directory [default: .]
        \\  --port PORT     Listening port [default: 6881]
        \\  --max-peers N   Maximum peers to connect to [default: 50]
        \\
    , .{});
}
