const std = @import("std");
const testing = std.testing;
const PieceManager = @import("piece_manager.zig").PieceManager;
const FileIO = @import("file_io.zig").FileIO;
const File = @import("torrent.zig").File;
const Allocator = std.mem.Allocator;

test "PieceManager initialization" {
    const allocator = testing.allocator;
    
    // Create test piece hashes
    const piece_hashes = [_][20]u8{
        [_]u8{1} ** 20,
        [_]u8{2} ** 20,
        [_]u8{3} ** 20,
    };
    
    // Create a copy of the piece hashes that we own
    var owned_hashes = try allocator.alloc([20]u8, piece_hashes.len);
    defer allocator.free(owned_hashes);
    
    for (piece_hashes, 0..) |hash, i| {
        owned_hashes[i] = hash;
    }
    
    // Initialize PieceManager
    var piece_manager = try PieceManager.init(
        allocator,
        16384, // piece_length
        3,     // total_pieces
        owned_hashes,
        "test_output.dat"
    );
    defer piece_manager.deinit();
    
    // Verify initial state
    try testing.expectEqual(@as(usize, 16384), piece_manager.piece_length);
    try testing.expectEqual(@as(usize, 3), piece_manager.total_pieces);
    try testing.expectEqual(@as(usize, 0), piece_manager.downloaded_pieces);
    try testing.expectEqual(@as(usize, 0), piece_manager.in_progress_pieces.count());
    try testing.expect(piece_manager.file_handle != null);
    
    // Verify bitfield is initialized to zeros
    for (piece_manager.bitfield) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "PieceManager hasPiece and markPieceComplete" {
    const allocator = testing.allocator;
    
    // Create test piece hashes
    const piece_hashes = [_][20]u8{
        [_]u8{1} ** 20,
        [_]u8{2} ** 20,
        [_]u8{3} ** 20,
    };
    
    // Create a copy of the piece hashes that we own
    var owned_hashes = try allocator.alloc([20]u8, piece_hashes.len);
    defer allocator.free(owned_hashes);
    
    for (piece_hashes, 0..) |hash, i| {
        owned_hashes[i] = hash;
    }
    
    // Initialize PieceManager
    var piece_manager = try PieceManager.init(
        allocator,
        16384, // piece_length
        3,     // total_pieces
        owned_hashes,
        "test_output.dat"
    );
    defer piece_manager.deinit();
    
    // Initially no pieces should be marked as complete
    try testing.expect(!piece_manager.hasPiece(0));
    try testing.expect(!piece_manager.hasPiece(1));
    try testing.expect(!piece_manager.hasPiece(2));
    
    // Mark piece 1 as complete
    piece_manager.markPieceComplete(1);
    
    // Verify piece 1 is now marked as complete
    try testing.expect(!piece_manager.hasPiece(0));
    try testing.expect(piece_manager.hasPiece(1));
    try testing.expect(!piece_manager.hasPiece(2));
    
    // Verify downloaded_pieces count is updated
    try testing.expectEqual(@as(usize, 1), piece_manager.downloaded_pieces);
    
    // Mark another piece as complete
    piece_manager.markPieceComplete(2);
    
    // Verify pieces 1 and 2 are now marked as complete
    try testing.expect(!piece_manager.hasPiece(0));
    try testing.expect(piece_manager.hasPiece(1));
    try testing.expect(piece_manager.hasPiece(2));
    
    // Verify downloaded_pieces count is updated
    try testing.expectEqual(@as(usize, 2), piece_manager.downloaded_pieces);
}

test "PieceManager verifyPiece" {
    const allocator = testing.allocator;
    
    // Create test piece hashes - we'll use the SHA1 of "test piece data"
    // SHA1("test piece data") = 3b9c24f0d5d2c4e93c5d7a3c3ba1d8b8e8f2a8a1
    const test_data = "test piece data";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(test_data);
    var hash: [20]u8 = undefined;
    hasher.final(&hash);
    
    var piece_hashes = [_][20]u8{hash};
    
    // Initialize PieceManager
    var piece_manager = try PieceManager.init(
        allocator,
        16384, // piece_length
        1,     // total_pieces
        &piece_hashes,
        "test_output.dat"
    );
    defer piece_manager.deinit();
    
    // Verify the correct piece data
    const valid = piece_manager.verifyPiece(0, test_data);
    try testing.expect(valid);
    
    // Verify incorrect piece data
    const invalid_data = "wrong piece data";
    const invalid = piece_manager.verifyPiece(0, invalid_data);
    try testing.expect(!invalid);
}

test "PieceManager isDownloadComplete" {
    const allocator = testing.allocator;
    
    // Create test piece hashes
    const piece_hashes = [_][20]u8{
        [_]u8{1} ** 20,
        [_]u8{2} ** 20,
    };
    
    // Initialize PieceManager
    var piece_manager = try PieceManager.init(
        allocator,
        16384, // piece_length
        2,     // total_pieces
        &piece_hashes,
        "test_output.dat"
    );
    defer piece_manager.deinit();
    
    // Initially download should not be complete
    try testing.expect(!piece_manager.isDownloadComplete());
    
    // Mark one piece as complete
    piece_manager.markPieceComplete(0);
    try testing.expect(!piece_manager.isDownloadComplete());
    
    // Mark all pieces as complete
    piece_manager.markPieceComplete(1);
    try testing.expect(piece_manager.isDownloadComplete());
}
