const std = @import("std");
const testing = std.testing;
const networking = @import("networking.zig");
const Allocator = std.mem.Allocator;
const net = std.net;

test "parseCompactPeers" {
    const allocator = testing.allocator;

    // Create test data for compact peers
    // Format: 4 bytes IP address + 2 bytes port (big endian)
    // Example: 192.168.1.1:6881 and 10.0.0.1:6882
    const test_data = [_]u8{
        192, 168, 1, 1, // IP: 192.168.1.1
        0x1A, 0xE1,     // Port: 6881 (0x1AE1)
        10, 0, 0, 1,    // IP: 10.0.0.1
        0x1A, 0xE2,     // Port: 6882 (0x1AE2)
    };

    // Parse the compact peers
    const peers = try networking.parseCompactPeers(allocator, &test_data);
    defer allocator.free(peers);

    // Verify the results
    try testing.expectEqual(@as(usize, 2), peers.len);

    // Check first peer
    const peer1 = peers[0];
    try testing.expect(peer1.any.family == std.os.AF.INET);

    // Convert to IPv4 address for easier comparison
    const ip1 = peer1.in;
    var ip1_bytes: [4]u8 = undefined;
    @memcpy(&ip1_bytes, &ip1.sa.addr);

    try testing.expectEqual(@as(u8, 192), ip1_bytes[0]);
    try testing.expectEqual(@as(u8, 168), ip1_bytes[1]);
    try testing.expectEqual(@as(u8, 1), ip1_bytes[2]);
    try testing.expectEqual(@as(u8, 1), ip1_bytes[3]);
    try testing.expectEqual(@as(u16, 6881), ip1.sa.port);

    // Check second peer
    const peer2 = peers[1];
    try testing.expect(peer2.any.family == std.os.AF.INET);

    // Convert to IPv4 address for easier comparison
    const ip2 = peer2.in;
    var ip2_bytes: [4]u8 = undefined;
    @memcpy(&ip2_bytes, &ip2.sa.addr);

    try testing.expectEqual(@as(u8, 10), ip2_bytes[0]);
    try testing.expectEqual(@as(u8, 0), ip2_bytes[1]);
    try testing.expectEqual(@as(u8, 0), ip2_bytes[2]);
    try testing.expectEqual(@as(u8, 1), ip2_bytes[3]);
    try testing.expectEqual(@as(u16, 6882), ip2.sa.port);
}

test "parseCompactPeers with empty data" {
    const allocator = testing.allocator;

    // Create empty test data
    const test_data = [_]u8{};

    // Parse the compact peers
    const peers = try networking.parseCompactPeers(allocator, &test_data);
    defer allocator.free(peers);

    // Verify the results
    try testing.expectEqual(@as(usize, 0), peers.len);
}

test "parseCompactPeers with incomplete data" {
    const allocator = testing.allocator;

    // Create test data with incomplete peer (only 5 bytes instead of 6)
    const test_data = [_]u8{
        192, 168, 1, 1, // IP: 192.168.1.1
        0x1A,           // Incomplete port
    };

    // Parse the compact peers - should ignore the incomplete peer
    const peers = try networking.parseCompactPeers(allocator, &test_data);
    defer allocator.free(peers);

    // Verify the results - should be empty since the data is incomplete
    try testing.expectEqual(@as(usize, 0), peers.len);
}

// Mock PeerManager for testing
test "PeerManager initialization" {
    const allocator = testing.allocator;

    // Create mock torrent file
    const torrent_file = @import("torrent.zig").TorrentFile{
        .announce_url = "http://example.com/announce",
        .info = .{
            .name = "test.txt",
            .piece_length = 16384,
            .pieces = "",
            .length = 1024,
            .files = null,
        },
        .info_raw = "",
    };

    // Create mock piece manager
    var piece_manager = @import("piece_manager.zig").PieceManager{
        .allocator = allocator,
        .piece_length = 16384,
        .total_pieces = 1,
        .piece_hashes = &[_][20]u8{[_]u8{0} ** 20},
        .bitfield = &[_]u8{0},
        .downloaded_pieces = 0,
        .file_io = null,
        .file_handle = null,
        .in_progress_pieces = std.AutoHashMap(usize, *anyopaque).init(allocator),
        .block_size = 16 * 1024,
        .mutex = std.Thread.Mutex{},
    };

    // Create mock file IO
    const files = [_]@import("torrent.zig").File{
        .{
            .path = "test.txt",
            .length = 1024,
        },
    };

    var file_io = @import("file_io.zig").FileIO{
        .allocator = allocator,
        .files = &files,
        .file_handles = &[_]std.fs.File{},
        .piece_length = 16384,
    };

    // Create peer ID and info hash
    const peer_id = [_]u8{0} ** 20;
    const info_hash = [_]u8{0} ** 20;

    // Initialize PeerManager
    var peer_manager = networking.PeerManager.init(
        allocator,
        torrent_file,
        &piece_manager,
        &file_io,
        peer_id,
        info_hash
    );
    defer peer_manager.deinit();

    // Verify initial state
    try testing.expectEqual(@as(usize, 0), peer_manager.peers.items.len);
    try testing.expectEqual(@as(usize, 0), peer_manager.getActivePeerCount());
}
