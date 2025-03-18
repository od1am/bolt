const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const PeerMessage = @import("peer_wire.zig").PeerMessage;
const PeerConnection = @import("peer_wire.zig").PeerConnection;

const Block = struct {
    data: []u8,
    begin: u32,
    length: u32,
    received: bool,
};

const Piece = struct {
    index: usize,
    blocks: []Block,
    total_blocks: usize,
    received_blocks: usize,
    complete: bool,
};

pub const PieceManager = struct {
    allocator: Allocator,
    piece_length: usize,
    total_pieces: usize,
    piece_hashes: []const [20]u8,
    bitfield: []u8,
    downloaded_pieces: usize,
    file_handle: std.fs.File,
    in_progress_pieces: std.AutoHashMap(usize, *Piece),
    block_size: u32,

    pub fn init(
        allocator: Allocator,
        piece_length: usize,
        total_pieces: usize,
        piece_hashes: []const [20]u8,
        output_file_path: []const u8,
    ) !PieceManager {
        const bitfield = try allocator.alloc(u8, (total_pieces + 7) / 8);
        @memset(bitfield, 0);

        const file_handle = try std.fs.cwd().createFile(output_file_path, .{ .truncate = true });

        return PieceManager{
            .allocator = allocator,
            .piece_length = piece_length,
            .total_pieces = total_pieces,
            .piece_hashes = piece_hashes,
            .bitfield = bitfield,
            .downloaded_pieces = 0,
            .file_handle = file_handle,
            .in_progress_pieces = std.AutoHashMap(usize, *Piece).init(allocator),
            .block_size = 16 * 1024, // 16KB blocks
        };
    }

    pub fn deinit(self: *PieceManager) void {
        var it = self.in_progress_pieces.valueIterator();
        while (it.next()) |piece_ptr| {
            const piece = piece_ptr.*;
            for (piece.blocks) |*block| {
                if (block.received) {
                    self.allocator.free(block.data);
                }
            }
            self.allocator.free(piece.blocks);
            self.allocator.destroy(piece);
        }
        self.in_progress_pieces.deinit();
        self.allocator.free(self.bitfield);
        self.file_handle.close();
    }

    pub fn hasPiece(self: *PieceManager, piece_index: usize) bool {
        const byte_index = piece_index / 8;
        const bit_index: u3 = @intCast(piece_index % 8);
        return (self.bitfield[byte_index] & (@as(u8, 1) << bit_index)) != 0;
    }

    pub fn markPieceComplete(self: *PieceManager, piece_index: usize) void {
        const byte_index = piece_index / 8;
        const bit_index: u3 = @intCast(piece_index % 8);
        self.bitfield[byte_index] |= (@as(u8, 1) << bit_index);
        self.downloaded_pieces += 1;
        std.debug.print("Piece {} complete! ({}/{} pieces)\n", .{ piece_index, self.downloaded_pieces, self.total_pieces });
    }

    pub fn verifyPiece(self: *PieceManager, piece_index: usize, piece_data: []const u8) bool {
        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(piece_data);
        var hash: [20]u8 = undefined;
        hasher.final(&hash);
        
        const expected_hash = self.piece_hashes[piece_index];
        const matches = std.mem.eql(u8, &hash, &expected_hash);
        
        if (!matches) {
            std.debug.print("Hash verification failed for piece {}:\n", .{piece_index});
            std.debug.print("  Expected: ", .{});
            for (expected_hash) |b| {
                std.debug.print("{x:0>2}", .{b});
            }
            std.debug.print("\n  Got:      ", .{});
            for (hash) |b| {
                std.debug.print("{x:0>2}", .{b});
            }
            std.debug.print("\n", .{});
        }
        
        return matches;
    }

    pub fn writePiece(self: *PieceManager, piece_index: usize, piece_data: []const u8) !void {
        const offset = piece_index * self.piece_length;
        try self.file_handle.seekTo(offset);
        try self.file_handle.writeAll(piece_data);
    }

    pub fn requestPiece(self: *PieceManager, peer: *PeerConnection, piece_index: usize) !void {
        const piece_size = if (piece_index == self.total_pieces - 1) blk: {
            const total_size = self.piece_length * self.total_pieces;
            const remaining = total_size - (piece_index * self.piece_length);
            break :blk @as(u32, @min(@as(u32, @intCast(remaining)), @as(u32, @intCast(self.piece_length))));
        } else @as(u32, @intCast(self.piece_length));

        std.debug.print("Requesting piece {} (size: {})\n", .{ piece_index, piece_size });

        // Create a new piece entry if it doesn't exist
        if (!self.in_progress_pieces.contains(piece_index)) {
            const num_blocks = (piece_size + self.block_size - 1) / self.block_size;
            var piece = try self.allocator.create(Piece);
            piece.* = Piece{
                .index = piece_index,
                .blocks = try self.allocator.alloc(Block, num_blocks),
                .total_blocks = num_blocks,
                .received_blocks = 0,
                .complete = false,
            };

            // Initialize blocks
            var i: usize = 0;
            var offset: u32 = 0;
            while (i < num_blocks) : (i += 1) {
                const length = @min(self.block_size, piece_size - offset);
                piece.blocks[i] = Block{
                    .data = undefined, // Will be allocated when received
                    .begin = offset,
                    .length = length,
                    .received = false,
                };
                offset += length;
            }

            try self.in_progress_pieces.put(piece_index, piece);
        }

        // Request all blocks for this piece
        const piece = self.in_progress_pieces.get(piece_index).?;
        for (piece.blocks) |block| {
            if (!block.received) {
                std.debug.print("Requesting block: piece={}, offset={}, length={}\n", .{ piece_index, block.begin, block.length });
                try peer.sendMessage(PeerMessage{
                    .request = .{
                        .index = @intCast(piece_index),
                        .begin = block.begin,
                        .length = block.length,
                    },
                });
            }
        }
    }

    pub fn markBlockReceived(self: *PieceManager, piece_index: u32, begin: u32, block_data: []const u8) void {
        const idx = @as(usize, piece_index);
        
        if (self.hasPiece(idx)) {
            std.debug.print("Already have piece {}, ignoring block\n", .{idx});
            return;
        }

        if (!self.in_progress_pieces.contains(idx)) {
            std.debug.print("Received block for piece {} which is not in progress, ignoring\n", .{idx});
            return;
        }

        const piece = self.in_progress_pieces.get(idx).?;
        
        // Find the block
        for (piece.blocks) |*block| {
            if (block.begin == begin and block.length == block_data.len) {
                if (block.received) {
                    std.debug.print("Already received block at offset {} for piece {}\n", .{ begin, idx });
                    return;
                }

                // Store the block data
                block.data = self.allocator.dupe(u8, block_data) catch {
                    std.debug.print("Failed to allocate memory for block data\n", .{});
                    return;
                };
                block.received = true;
                piece.received_blocks += 1;

                std.debug.print("Received block {}/{} for piece {}\n", .{ piece.received_blocks, piece.total_blocks, idx });

                // Check if piece is complete
                if (piece.received_blocks == piece.total_blocks) {
                    self.processPiece(piece) catch |err| {
                        std.debug.print("Failed to process piece {}: {}\n", .{ idx, err });
                    };
                }
                return;
            }
        }

        std.debug.print("Received block with unexpected offset {} or length {} for piece {}\n", .{ begin, block_data.len, idx });
    }

    fn processPiece(self: *PieceManager, piece: *Piece) !void {
        std.debug.print("Processing complete piece {}\n", .{piece.index});

        // Calculate total size of the piece
        var total_size: usize = 0;
        for (piece.blocks) |block| {
            total_size += block.length;
        }

        // Combine all blocks into a single buffer
        var piece_data = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(piece_data);

        var offset: usize = 0;
        for (piece.blocks) |block| {
            @memcpy(piece_data[offset .. offset + block.length], block.data[0..block.length]);
            offset += block.length;
        }

        // Verify the piece hash
        if (self.verifyPiece(piece.index, piece_data)) {
            std.debug.print("Piece {} verified successfully\n", .{piece.index});
            
            // Write the piece to disk
            try self.writePiece(piece.index, piece_data);
            
            // Mark the piece as complete
            self.markPieceComplete(piece.index);
            
            // Clean up the piece data
            for (piece.blocks) |*block| {
                if (block.received) {
                    self.allocator.free(block.data);
                }
            }
            
            // Remove from in-progress map
            _ = self.in_progress_pieces.remove(piece.index);
            self.allocator.free(piece.blocks);
            self.allocator.destroy(piece);
        } else {
            std.debug.print("Piece {} verification failed, will re-download\n", .{piece.index});
            
            // Reset the piece to try again
            for (piece.blocks) |*block| {
                if (block.received) {
                    self.allocator.free(block.data);
                    block.received = false;
                }
            }
            piece.received_blocks = 0;
        }
    }

    pub fn isDownloadComplete(self: *PieceManager) bool {
        const complete = self.downloaded_pieces == self.total_pieces;
        if (complete) {
            std.debug.print("Download is complete! ({}/{} pieces)\n", .{ self.downloaded_pieces, self.total_pieces });
        }
        return complete;
    }

    pub fn getNextNeededPiece(self: *PieceManager) ?usize {
        var i: usize = 0;
        while (i < self.total_pieces) : (i += 1) {
            if (!self.hasPiece(i) and !self.in_progress_pieces.contains(i)) {
                std.debug.print("Next needed piece: {}\n", .{i});
                return i;
            }
        }
        std.debug.print("No more pieces needed\n", .{});
        return null;
    }
};
