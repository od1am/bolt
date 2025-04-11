const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");
const Allocator = std.mem.Allocator;

test "generatePeerId" {
    // Generate two peer IDs and make sure they're different
    const peer_id1 = config.generatePeerId();
    const peer_id2 = config.generatePeerId();

    // Check that the peer IDs are not equal
    try testing.expect(!std.mem.eql(u8, &peer_id1, &peer_id2));

    // Check that the peer ID is 20 bytes
    try testing.expectEqual(@as(usize, 20), peer_id1.len);
}
