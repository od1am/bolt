const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Config = struct {
    torrent_path: []const u8,
    output_dir: []const u8,
    listen_port: u16,
    max_peers: u8,
    peer_id: [20]u8,

    pub fn deinit(self: *Config, allocator: Allocator) void {
        allocator.free(self.torrent_path);
        allocator.free(self.output_dir);
    }
};

pub const default_config = Config{
    .torrent_path = "",
    .output_dir = ".",
    .listen_port = 6881,
    .max_peers = 50,
    .peer_id = undefined,
};

pub fn generatePeerId() [20]u8 {
    var peer_id: [20]u8 = undefined;
    std.crypto.random.bytes(&peer_id);
    return peer_id;
}
