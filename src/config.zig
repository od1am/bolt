const std = @import("std");
const Allocator = std.mem.Allocator;

// Configuration settings for the client
pub const Config = struct {
    torrent_path: []const u8, // Path to .torrent file (required)
    output_dir: []const u8, // Output directory for downloaded files
    listen_port: u16, // Port to listen for incoming connections
    max_peers: u8, // Maximum number of peers to connect to
    peer_id: [20]u8, // Client peer ID (random if not specified)

    pub fn deinit(self: *Config, allocator: Allocator) void {
        allocator.free(self.torrent_path);
        allocator.free(self.output_dir);
    }
};

// Default configuration values
pub const default_config = Config{
    .torrent_path = "",
    .output_dir = ".",
    .listen_port = 6881,
    .max_peers = 50,
    .peer_id = undefined, // Will be populated later
};

// Generate a random peer ID if none is specified
pub fn generatePeerId() [20]u8 {
    var peer_id: [20]u8 = undefined;
    std.crypto.random.bytes(&peer_id);
    return peer_id;
}
