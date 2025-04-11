const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const PeerMessage = @import("peer_wire.zig").PeerMessage;
const PeerConnection = @import("peer_wire.zig").PeerConnection;
const FileIO = @import("file_io.zig").FileIO;

const Block = struct {
    data: []u8,
    begin: u32,
    length: u32,
    received: bool,
    requested_time: i64, // Timestamp when the block was last requested
};

const Piece = struct {
    index: usize,
    blocks: []Block,
    total_blocks: usize,
    received_blocks: usize,
    complete: bool,
    last_activity: i64, // Timestamp of last block received
};

pub const PieceManager = struct {
    allocator: Allocator,
    piece_length: usize,
    total_pieces: usize,
    piece_hashes: []const [20]u8,
    bitfield: []u8,
    downloaded_pieces: usize,
    file_io: ?*FileIO,
    file_handle: ?std.fs.File,
    in_progress_pieces: std.AutoHashMap(usize, *Piece),
    block_size: u32,
    mutex: std.Thread.Mutex, // Mutex to protect shared data structures

    pub fn init(
        allocator: Allocator,
        piece_length: usize,
        total_pieces: usize,
        piece_hashes: []const [20]u8,
        output_file_path: []const u8,
    ) !PieceManager {
        const bitfield = try allocator.alloc(u8, (total_pieces + 7) / 8);
        @memset(bitfield, 0);

        // Create a file handle only for single-file torrents
        var file_handle: ?std.fs.File = null;
        if (!std.mem.eql(u8, output_file_path, "temp_data")) {
            file_handle = try std.fs.cwd().createFile(output_file_path, .{ .truncate = true });
        }

        return PieceManager{
            .allocator = allocator,
            .piece_length = piece_length,
            .total_pieces = total_pieces,
            .piece_hashes = piece_hashes,
            .bitfield = bitfield,
            .downloaded_pieces = 0,
            .file_io = null,
            .file_handle = file_handle,
            .in_progress_pieces = std.AutoHashMap(usize, *Piece).init(allocator),
            .block_size = 16 * 1024, // 16KB blocks
            .mutex = std.Thread.Mutex{},
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
        if (self.file_handle) |*file_handle| {
            file_handle.close();
        }
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
        if (self.file_io) |file_io| {
            // Use the FileIO for multi-file torrents
            try file_io.writeBlock(piece_index, 0, piece_data);
        } else if (self.file_handle) |*file_handle| {
            // For single-file torrents, use direct file handle
            const offset = piece_index * self.piece_length;
            try file_handle.seekTo(offset);
            try file_handle.writeAll(piece_data);
        } else {
            return error.NoFileHandlerAvailable;
        }
    }

    pub fn requestPiece(self: *PieceManager, peer: *PeerConnection, piece_index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_time = std.time.milliTimestamp();

        // Limit the number of in-progress pieces to prevent memory issues
        const max_in_progress_pieces = 50;
        if (self.in_progress_pieces.count() >= max_in_progress_pieces) {
            // Clean up any stale in-progress pieces
            self.cleanupStalePieces();

            // If we're still at the limit, don't start another piece
            if (self.in_progress_pieces.count() >= max_in_progress_pieces) {
                std.debug.print("Too many in-progress pieces ({}), not starting new piece {}\n", .{ self.in_progress_pieces.count(), piece_index });
                return error.TooManyInProgressPieces;
            }
        }

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
                .last_activity = current_time,
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
                    .requested_time = 0, // Not requested yet
                };
                offset += length;
            }

            try self.in_progress_pieces.put(piece_index, piece);
        }

        // Request only the blocks that haven't been received yet
        const piece = self.in_progress_pieces.get(piece_index).?;
        var requested_blocks: usize = 0;
        const max_requests = 16; // Don't request too many blocks at once to avoid overwhelming the peer
        const block_request_timeout = 30 * 1000; // 30 seconds before considering a block request timed out

        // Update the piece's last activity time
        piece.last_activity = current_time;

        for (piece.blocks) |*block| {
            // Skip blocks we've already received
            if (block.received) continue;

            // Check if this block was requested recently
            const request_age = current_time - block.requested_time;
            const should_request = block.requested_time == 0 or request_age > block_request_timeout;

            if (should_request) {
                std.debug.print("DOWNLOAD REQUEST: Requesting block for piece={}, offset={}, length={}\n", .{ piece_index, block.begin, block.length });

                try peer.sendMessage(PeerMessage{
                    .request = .{
                        .index = @intCast(piece_index),
                        .begin = block.begin,
                        .length = block.length,
                    },
                });

                // Update the requested time
                block.requested_time = current_time;

                requested_blocks += 1;
                if (requested_blocks >= max_requests) {
                    break; // Don't request too many at once
                }
            }
        }

        if (requested_blocks == 0 and piece.received_blocks < piece.total_blocks) {
            // If all blocks have been requested but not received, and enough time has passed,
            // we could force re-request some blocks
            var force_requested: usize = 0;
            const force_max_requests = 5; // Limit the number of force-requested blocks

            for (piece.blocks) |*block| {
                if (!block.received) {
                    const request_age = current_time - block.requested_time;
                    // If the block request is older than twice our timeout threshold, force re-request
                    if (request_age > block_request_timeout * 2) {
                        std.debug.print("DOWNLOAD RETRY: Force re-requesting block for piece={}, offset={}, length={}\n", .{ piece_index, block.begin, block.length });

                        try peer.sendMessage(PeerMessage{
                            .request = .{
                                .index = @intCast(piece_index),
                                .begin = block.begin,
                                .length = block.length,
                            },
                        });

                        // Update the requested time
                        block.requested_time = current_time;

                        force_requested += 1;
                        if (force_requested >= force_max_requests) {
                            break; // Limit the number of force re-requests
                        }
                    }
                }
            }

            if (force_requested == 0) {
                std.debug.print("Warning: No blocks to request for piece {}, but piece is not complete ({}/{} blocks)\n", .{ piece_index, piece.received_blocks, piece.total_blocks });
            }
        }
    }

    pub fn markBlockReceived(self: *PieceManager, piece_index: u32, begin: u32, block_data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = @as(usize, piece_index);
        const current_time = std.time.milliTimestamp();

        if (self.hasPiece(idx)) {
            std.debug.print("Already have piece {}, ignoring block\n", .{idx});
            return;
        }

        if (!self.in_progress_pieces.contains(idx)) {
            std.debug.print("Received block for piece {} which is not in progress, ignoring\n", .{idx});
            return;
        }

        const piece = self.in_progress_pieces.get(idx).?;

        // Update the piece's last activity time
        piece.last_activity = current_time;

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
        // The mutex is already locked in markBlockReceived before this is called
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

            // Write piece data to disk
            try self.writePiece(piece.index, piece_data);
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
                }
                // Create a fresh buffer for this block
                block.data = try self.allocator.alloc(u8, block.length);
                block.received = false;
                block.requested_time = 0; // Reset request time
            }
            piece.received_blocks = 0;
            piece.last_activity = std.time.milliTimestamp(); // Update activity time
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

    fn cleanupStalePieces(self: *PieceManager) void {
        const current_time = std.time.milliTimestamp();
        const stale_threshold = 120 * 1000; // 2 minutes without activity

        var stale_keys = std.ArrayList(usize).init(self.allocator);
        defer stale_keys.deinit();

        var it = self.in_progress_pieces.iterator();
        while (it.next()) |entry| {
            const piece_index = entry.key_ptr.*;
            const piece = entry.value_ptr.*;

            const age = current_time - piece.last_activity;
            if (age > stale_threshold) {
                std.debug.print("Piece {} is stale (no activity for {} seconds), marking for cleanup\n", .{ piece_index, @divFloor(age, 1000) });
                stale_keys.append(piece_index) catch continue;
            }
        }

        // Now remove all stale pieces
        for (stale_keys.items) |key| {
            if (self.in_progress_pieces.get(key)) |piece| {
                for (piece.blocks) |*block| {
                    if (block.received) {
                        self.allocator.free(block.data);
                    }
                }
                self.allocator.free(piece.blocks);
                self.allocator.destroy(piece);
                _ = self.in_progress_pieces.remove(key);
                std.debug.print("Cleaned up stale piece {}\n", .{key});
            }
        }
    }

    // Add method to set FileIO reference
    pub fn setFileIO(self: *PieceManager, file_io: *FileIO) void {
        self.file_io = file_io;
    }
};
