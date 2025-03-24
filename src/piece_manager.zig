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

        std.debug.print("DOWNLOAD STARTED: Requesting piece {} (size: {})\n", .{ piece_index, piece_size });

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
                    .data = try self.allocator.alloc(u8, length),
                    .begin = offset,
                    .length = length,
                    .received = false,
                };
                offset += length;
            }

            try self.in_progress_pieces.put(piece_index, piece);
        }

        // Request only the blocks that haven't been received yet
        const piece = self.in_progress_pieces.get(piece_index).?;
        var requested_blocks: usize = 0;
        const max_requests = 16; // Don't request too many blocks at once to avoid overwhelming the peer

        for (piece.blocks) |block| {
            if (!block.received) {
                std.debug.print("DOWNLOAD REQUEST: Requesting block for piece={}, offset={}, length={}\n", .{ piece_index, block.begin, block.length });
                try peer.sendMessage(PeerMessage{
                    .request = .{
                        .index = @intCast(piece_index),
                        .begin = block.begin,
                        .length = block.length,
                    },
                });

                requested_blocks += 1;
                if (requested_blocks >= max_requests) {
                    break; // Don't request too many at once
                }
            }
        }

        if (requested_blocks == 0 and piece.received_blocks < piece.total_blocks) {
            // Something went wrong, the piece should have unreceived blocks
            std.debug.print("Warning: No blocks to request for piece {}, but piece is not complete ({}/{} blocks)\n", .{ piece_index, piece.received_blocks, piece.total_blocks });
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

                // Copy the block data instead of duplicating to prevent memory leaks
                @memcpy(block.data[0..block_data.len], block_data);
                block.received = true;
                piece.received_blocks += 1;

                std.debug.print("DOWNLOAD PROGRESS: Received block {}/{} for piece {} (offset: {}, size: {})\n", .{ piece.received_blocks, piece.total_blocks, idx, begin, block_data.len });

                // Check if piece is complete
                if (piece.received_blocks == piece.total_blocks) {
                    std.debug.print("DOWNLOAD MILESTONE: All blocks for piece {} received, verifying...\n", .{idx});
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
        std.debug.print("DOWNLOAD VERIFICATION: Processing complete piece {}\n", .{piece.index});

        // Calculate total size of the piece
        var total_size: usize = 0;
        for (piece.blocks) |block| {
            total_size += block.length;
        }

        // Combine all blocks into a single buffer for verification
        var piece_data = try self.allocator.alloc(u8, total_size);
        defer self.allocator.free(piece_data);

        var offset: usize = 0;
        for (piece.blocks) |block| {
            @memcpy(piece_data[offset .. offset + block.length], block.data[0..block.length]);
            offset += block.length;
        }

        // Verify the piece hash
        if (self.verifyPiece(piece.index, piece_data)) {
            std.debug.print("DOWNLOAD SUCCESS: Piece {} verified successfully\n", .{piece.index});

            // Write each block to disk
            offset = 0;
            for (piece.blocks) |block| {
                try self.file_handle.seekTo(piece.index * self.piece_length + block.begin);
                try self.file_handle.writeAll(block.data[0..block.length]);
                offset += block.length;
            }
            std.debug.print("DOWNLOAD WRITE: Piece {} written to disk\n", .{piece.index});

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
        // First, try to find a piece that isn't in progress and hasn't been downloaded
        var rng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = rng.random();

        // Collect all available pieces
        var available_pieces = std.ArrayList(usize).init(self.allocator);
        defer available_pieces.deinit();

        // Find pieces that are not downloaded and not in progress
        var i: usize = 0;
        while (i < self.total_pieces) : (i += 1) {
            if (!self.hasPiece(i) and !self.in_progress_pieces.contains(i)) {
                available_pieces.append(i) catch {
                    continue; // If we can't append, just try the next piece
                };
            }
        }

        // If there are available pieces, select one randomly
        if (available_pieces.items.len > 0) {
            const random_index = random.intRangeLessThan(usize, 0, available_pieces.items.len);
            const piece = available_pieces.items[random_index];
            std.debug.print("Next needed piece: {} (chosen from {} available pieces)\n", .{ piece, available_pieces.items.len });
            return piece;
        }

        // If no completely free pieces, look for pieces with the fewest blocks received
        // (this helps distribute work across peers more efficiently)
        if (self.in_progress_pieces.count() > 0) {
            var min_blocks: usize = std.math.maxInt(usize);
            var min_piece: ?usize = null;

            var it = self.in_progress_pieces.iterator();
            while (it.next()) |entry| {
                const piece_index = entry.key_ptr.*;
                const piece = entry.value_ptr.*;

                if (piece.received_blocks < min_blocks) {
                    min_blocks = piece.received_blocks;
                    min_piece = piece_index;
                }
            }

            if (min_piece != null) {
                std.debug.print("Resuming in-progress piece: {} (has {} of {} blocks)\n", .{ min_piece.?, min_blocks, self.in_progress_pieces.get(min_piece.?).?.total_blocks });
                return min_piece;
            }
        }

        std.debug.print("No more pieces needed\n", .{});
        return null;
    }
};
