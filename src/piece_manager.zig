const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const PeerMessage = @import("peer_wire.zig").PeerMessage;
const PeerConnection = @import("peer_wire.zig").PeerConnection;

// PieceManager manages the downloading and verification of pieces
pub const PieceManager = struct {
    allocator: Allocator,
    piece_length: usize,
    total_pieces: usize,
    piece_hashes: []const [20]u8, // SHA-1 hashes of each piece
    bitfield: []u8, // Tracks which pieces have been downloaded
    downloaded_pieces: usize, // Number of pieces downloaded so far
    file_handle: std.fs.File, // File handle for writing downloaded data

    pub fn init(
        allocator: Allocator,
        piece_length: usize,
        total_pieces: usize,
        piece_hashes: []const [20]u8,
        output_file_path: []const u8,
    ) !PieceManager {
        const bitfield = try allocator.alloc(u8, (total_pieces + 7) / 8);
        @memset(bitfield, 0); // Initialize bitfield to 0

        const file_handle = try std.fs.cwd().createFile(output_file_path, .{ .truncate = true });

        return PieceManager{
            .allocator = allocator,
            .piece_length = piece_length,
            .total_pieces = total_pieces,
            .piece_hashes = piece_hashes,
            .bitfield = bitfield,
            .downloaded_pieces = 0,
            .file_handle = file_handle,
        };
    }

    pub fn deinit(self: *PieceManager) void {
        self.allocator.free(self.bitfield);
        self.file_handle.close();
    }

    // Check if a piece has been downloaded
    pub fn hasPiece(self: *PieceManager, piece_index: usize) bool {
        const byte_index = piece_index / 8;
        const bit_index: u3 = @intCast(piece_index % 8); // Cast to u3 for fixed-width
        return (self.bitfield[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }

    // Mark a piece as downloaded
    pub fn markPieceComplete(self: *PieceManager, piece_index: usize) void {
        const byte_index = piece_index / 8;
        const bit_index: u3 = @intCast(piece_index % 8); // Cast to u3 for fixed-width
        self.bitfield[byte_index] |= (@as(u8, 1) << bit_index);
        self.downloaded_pieces += 1;
    }

    // Verify the integrity of a downloaded piece
    pub fn verifyPiece(self: *PieceManager, piece_index: usize, piece_data: []const u8) bool {
        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(piece_data);
        const hash = hasher.finalResult();
        return std.mem.eql(u8, &hash, &self.piece_hashes[piece_index]);
    }

    // Write a downloaded piece to disk
    pub fn writePiece(self: *PieceManager, piece_index: usize, piece_data: []const u8) !void {
        const offset = piece_index * self.piece_length;
        try self.file_handle.seekTo(offset);
        try self.file_handle.writeAll(piece_data);
    }
    // Request a piece from a peer
    pub fn requestPiece(self: *PieceManager, peer: *PeerConnection, piece_index: usize) !void {
        const block_size: u32 = 16 * 1024; // 16 KB block size
        const piece_size = if (piece_index == self.total_pieces - 1) blk: {
            const total_size = self.piece_length * self.total_pieces;
            const remaining = total_size - (piece_index * self.piece_length);
            break :blk @as(u32, @min(@as(u32, @intCast(remaining)), @as(u32, @intCast(self.piece_length))));
        } else @as(u32, @intCast(self.piece_length));

        std.debug.print("Requesting piece {} (size: {})\n", .{ piece_index, piece_size });

        var offset: u32 = 0;
        while (offset < piece_size) {
            const length = @min(block_size, piece_size - offset);
            std.debug.print("Requesting block: piece={}, offset={}, length={}\n", .{ piece_index, offset, length });

            try peer.sendMessage(PeerMessage{
                .request = .{
                    .index = @intCast(piece_index),
                    .begin = offset,
                    .length = length,
                },
            });
            offset += length;
        }
    }

    // Handle a received piece message
    pub fn handlePieceMessage(self: *PieceManager, piece_index: usize, begin: u32, block: []const u8) !void {
        const offset = piece_index * self.piece_length + begin;
        std.debug.print("Writing block to file: piece={}, offset={}, size={}\n", .{ piece_index, offset, block.len });

        try self.file_handle.seekTo(offset);
        try self.file_handle.writeAll(block);
    }

    // Check if all pieces have been downloaded
    pub fn isDownloadComplete(self: *PieceManager) bool {
        const complete = self.downloaded_pieces == self.total_pieces;
        if (complete) {
            std.debug.print("Download is complete! ({}/{} pieces)\n", .{ self.downloaded_pieces, self.total_pieces });
        }
        return complete;
    }

    // Get the index of the next piece that needs to be downloaded
    // Returns null if all pieces are downloaded or in progress
    pub fn getNextNeededPiece(self: *PieceManager) ?usize {
        var i: usize = 0;
        while (i < self.total_pieces) : (i += 1) {
            if (!self.hasPiece(i)) {
                std.debug.print("Next needed piece: {}\n", .{i});
                return i;
            }
        }
        std.debug.print("No more pieces needed\n", .{});
        return null;
    }
    // Add this new method to track received blocks
    pub fn markBlockReceived(self: *PieceManager, piece_index: u32, begin: u32, length: usize) void {
        _ = begin;
        _ = length;
        std.debug.print("Marking piece {} as complete\n", .{piece_index});
        self.markPieceComplete(piece_index);
    }
};
