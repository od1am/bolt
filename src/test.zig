const std = @import("std");
const testing = std.testing;

const bencode = @import("bencode.zig");
const cli = @import("cli.zig");
const config = @import("config.zig");
const file_io = @import("file_io.zig");
const main = @import("main.zig");
const metrics = @import("metrics.zig");
const networking = @import("networking.zig");
const peer_wire = @import("peer_wire.zig");
const piece_manager = @import("piece_manager.zig");
const thread_pool = @import("thread_pool.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");

test {
    _ = bencode;
    _ = cli;
    _ = config;
    _ = file_io;
    _ = main;
    _ = metrics;
    _ = networking;
    _ = peer_wire;
    _ = piece_manager;
    _ = thread_pool;
    _ = torrent;
    _ = tracker;
}
