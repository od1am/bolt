const std = @import("std");
const builtin = @import("builtin");
const ArrayList = std.ArrayList;
const debug = std.debug;
const os = std.os;
const linux = os.linux;
const net = std.net;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const PeerConnection = @import("peer_wire.zig").PeerConnection;
const PieceManager = @import("piece_manager.zig").PieceManager;
const FileIO = @import("file_io.zig").FileIO;
const TorrentFile = @import("torrent.zig").TorrentFile;
const tracker_module = @import("tracker.zig");
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const Task = @import("thread_pool.zig").Task;
const Metrics = @import("metrics.zig").Metrics;

const Protocol = enum {
    tcp,
    udp,
};

// Optional local address to bind outgoing connections to
var local_address: ?net.Address = null;

// Function to set the local address for outgoing connections
pub fn setLocalAddress(address_str: []const u8, port: u16) !void {
    local_address = try net.Address.parseIp(address_str, port);
    debug.print("Local address set to {}:{}\n", .{ address_str, port });
}

// PeerContext holds the context for a peer connection task
pub const PeerContext = struct {
    peer_manager: *PeerManager,
    peer: *PeerConnection,
};

// PeerManager coordinates connections to multiple peers
pub const PeerManager = struct {
    allocator: Allocator,
    torrent_file: TorrentFile,
    piece_manager: *PieceManager,
    file_io: *FileIO,
    peers: ArrayList(PeerConnection),
    peer_id: [20]u8,
    info_hash: [20]u8,
    active_peers: std.atomic.Value(usize),
    mutex: std.Thread.Mutex,
    thread_pool: ?*ThreadPool,
    metrics: ?*Metrics,

    pub fn init(
        allocator: Allocator,
        torrent_file: TorrentFile,
        piece_manager: *PieceManager,
        file_io: *FileIO,
        peer_id: [20]u8,
        info_hash: [20]u8,
    ) !PeerManager {
        // Create a thread pool with a fixed number of threads to avoid any potential issues
        // Use a conservative number of threads that should work on any system
        const thread_count: u8 = 4; // Fixed number of threads to avoid any potential issues

        const thread_pool = try allocator.create(ThreadPool);
        errdefer allocator.destroy(thread_pool);

        thread_pool.* = try ThreadPool.init(allocator, thread_count, 100);

        // Create metrics collector
        const metrics = try allocator.create(Metrics);
        errdefer allocator.destroy(metrics);

        metrics.* = Metrics.init(allocator);

        return PeerManager{
            .allocator = allocator,
            .torrent_file = torrent_file,
            .piece_manager = piece_manager,
            .file_io = file_io,
            .peers = ArrayList(PeerConnection).init(allocator),
            .peer_id = peer_id,
            .info_hash = info_hash,
            .active_peers = std.atomic.Value(usize).init(0),
            .mutex = std.Thread.Mutex{},
            .thread_pool = thread_pool,
            .metrics = metrics,
        };
    }

    // Simplified initialization without thread pool to avoid issues
    pub fn initSimple(
        allocator: Allocator,
        torrent_file: TorrentFile,
        piece_manager: *PieceManager,
        file_io: *FileIO,
        peer_id: [20]u8,
        info_hash: [20]u8,
    ) !PeerManager {
        // Create metrics collector
        const metrics = try allocator.create(Metrics);
        errdefer allocator.destroy(metrics);

        metrics.* = Metrics.init(allocator);

        return PeerManager{
            .allocator = allocator,
            .torrent_file = torrent_file,
            .piece_manager = piece_manager,
            .file_io = file_io,
            .peers = ArrayList(PeerConnection).init(allocator),
            .peer_id = peer_id,
            .info_hash = info_hash,
            .active_peers = std.atomic.Value(usize).init(0),
            .mutex = std.Thread.Mutex{},
            .thread_pool = null,
            .metrics = metrics,
        };
    }

    pub fn deinit(self: *PeerManager) void {
        // Clean up thread pool
        if (self.thread_pool) |thread_pool| {
            thread_pool.deinit();
            self.allocator.destroy(thread_pool);
        }

        // Clean up metrics
        if (self.metrics) |metrics| {
            metrics.deinit();
            self.allocator.destroy(metrics);
        }

        // Clean up peers
        for (self.peers.items) |*peer| {
            peer.deinit();
        }
        self.peers.deinit();
    }

    pub fn getActivePeerCount(self: *PeerManager) usize {
        return self.active_peers.load(.monotonic);
    }

    // Connect to a peer and add it to the list
    pub fn connectToPeer(self: *PeerManager, address: net.Address) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ip_buf: [100]u8 = undefined;
        const ip = try std.fmt.bufPrint(&ip_buf, "{}", .{address});

        debug.print("Attempting to connect to peer {s}\n", .{ip});

        // Record connection attempt in metrics
        if (self.metrics) |metrics| {
            metrics.recordConnectionAttempt();
        }

        // Create a socket with a shorter timeout
        const socket = if (local_address) |local_addr| blk: {
            // Create an unconnected socket
            const sock = try posix.socket(local_addr.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            errdefer {
                // Safely close the socket - in Zig 0.13 posix.close doesn't return an error
                posix.close(sock);
            }

            // Set a connection timeout - this helps with stalled connections
            if (@hasDecl(posix, "SO_RCVTIMEO")) {
                const timeout = posix.timeval{
                    .tv_sec = 3, // 3 second connection timeout
                    .tv_usec = 0,
                };
                posix.setsockopt(
                    sock,
                    posix.SOL.SOCKET,
                    posix.SO.RCVTIMEO,
                    std.mem.asBytes(&timeout),
                ) catch |err| {
                    debug.print("Warning: Failed to set socket timeout: {}\n", .{err});
                };

                // Also set send timeout
                posix.setsockopt(
                    sock,
                    posix.SOL.SOCKET,
                    posix.SO.SNDTIMEO,
                    std.mem.asBytes(&timeout),
                ) catch |err| {
                    debug.print("Warning: Failed to set socket send timeout: {}\n", .{err});
                };
            }

            // Bind to the local address
            try posix.bind(sock, &local_addr.any, local_addr.getOsSockLen());

            // Connect to the peer
            try posix.connect(sock, &address.any, address.getOsSockLen());

            break :blk std.net.Stream{ .handle = sock };
        } else std.net.tcpConnectToAddress(address) catch |err| {
            debug.print("Failed to connect to peer {s}: {}\n", .{ ip, err });

            // Record failed connection in metrics
            if (self.metrics) |metrics| {
                metrics.recordFailedConnection();
            }

            return err;
        };
        errdefer {
            // Safely close the socket - in Zig 0.13 std.net.Stream.close() also returns void
            socket.close();

            // Record failed connection in metrics
            if (self.metrics) |metrics| {
                metrics.recordFailedConnection();
            }
        }

        // For non-blocking socket operations, we'll use a manual timer approach
        // instead of relying on socket options that may vary across Zig versions
        const start_time = std.time.milliTimestamp();
        const timeout_ms = 5000; // 5 seconds timeout for handshake (increased from 3s)

        var peer = PeerConnection{
            .socket = socket,
            .peer_id = self.peer_id,
            .info_hash = self.info_hash,
            .allocator = self.allocator,
        };

        // Perform handshake with timeout check
        peer.handshake() catch |err| {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed >= timeout_ms) {
                debug.print("Handshake timed out after {} ms for peer {s}\n", .{ elapsed, ip });
            } else {
                debug.print("Handshake failed with peer {s}: {}\n", .{ ip, err });
            }

            // Safely close the socket, catching any potential errors
            debug.print("Closing socket after handshake failure\n", .{});
            socket.close();

            // Record failed connection in metrics
            if (self.metrics) |metrics| {
                metrics.recordFailedConnection();
            }

            return err;
        };

        try self.peers.append(peer);
        debug.print("Successfully connected to peer {s}\n", .{ip});

        // Record successful connection in metrics
        if (self.metrics) |metrics| {
            metrics.recordSuccessfulConnection();
        }
    }

    // Start downloading pieces from all connected peers
    pub fn startDownload(self: *PeerManager) !void {
        debug.print("Starting download with {} connected peers\n", .{self.peers.items.len});

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we have any peers
        if (self.peers.items.len == 0) {
            debug.print("No peers connected, cannot start download\n", .{});
            return error.NoPeersConnected;
        }

        // If we have a thread pool, use it
        if (self.thread_pool != null) {
            for (self.peers.items) |*peer| {
                debug.print("Sending interested message to peer\n", .{});
                try peer.sendMessage(.interested);

                // Create a context for this peer task
                const context = try self.allocator.create(PeerContext);
                context.* = PeerContext{
                    .peer_manager = self,
                    .peer = peer,
                };

                // Submit the peer handling task to the thread pool
                try self.thread_pool.?.submit(Task{
                    .function = peerTaskFunction,
                    .context = context,
                });
            }
        } else {
            // No thread pool, just use the first peer directly
            debug.print("Using simplified download with first peer\n", .{});
            var peer = &self.peers.items[0];
            try peer.sendMessage(.interested);

            // Handle the peer directly
            try handlePeer(self, peer);
        }
    }

    // Add a new peer to the download process (for newly connected peers)
    pub fn addPeerToDownload(self: *PeerManager, peer_index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (peer_index >= self.peers.items.len) {
            return error.InvalidPeerIndex;
        }

        var peer = &self.peers.items[peer_index];
        debug.print("Adding new peer to download process\n", .{});
        try peer.sendMessage(.interested);

        // If we have a thread pool, use it
        if (self.thread_pool != null) {
            // Create a context for this peer task
            const context = try self.allocator.create(PeerContext);
            context.* = PeerContext{
                .peer_manager = self,
                .peer = peer,
            };

            // Submit the peer handling task to the thread pool
            try self.thread_pool.?.submit(Task{
                .function = peerTaskFunction,
                .context = context,
            });
        } else {
            // No thread pool, just handle the peer directly if we're not already downloading
            if (self.piece_manager.isDownloadComplete()) {
                debug.print("Download already complete, not adding new peer\n", .{});
                return;
            }

            // Only add the peer if we don't have any active peers
            if (self.active_peers.load(.monotonic) == 0) {
                debug.print("No active peers, adding new peer for direct download\n", .{});
                try handlePeer(self, peer);
            }
        }
    }

    // Function that wraps handlePeer for the thread pool
    fn peerTaskFunction(context_ptr: *anyopaque) void {
        const context = @as(*PeerContext, @ptrCast(@alignCast(context_ptr)));
        defer context.peer_manager.allocator.destroy(context);

        handlePeer(context.peer_manager, context.peer) catch |err| {
            debug.print("Peer task failed: {}\n", .{err});
        };
    }

    // Handle messages from a single peer (runs in the thread pool)
    fn handlePeer(self: *PeerManager, peer: *PeerConnection) !void {
        _ = self.active_peers.fetchAdd(1, .monotonic);
        defer {
            _ = self.active_peers.fetchSub(1, .monotonic);
            debug.print("Peer disconnected, active peers: {}\n", .{self.active_peers.load(.monotonic)});

            // Record peer disconnection in metrics
            if (self.metrics) |metrics| {
                metrics.recordPeerDisconnection();
            }
        }

        defer peer.deinit();
        var peer_has_pieces = std.ArrayList(usize).init(self.allocator);
        defer peer_has_pieces.deinit();

        var is_choked = true;
        var has_sent_interested = false;
        var current_piece: ?usize = null;
        var last_message_time = std.time.milliTimestamp();
        var last_piece_progress_time = std.time.milliTimestamp();
        const timeout_ms = 90 * 1000; // 90 seconds timeout for general inactivity (increased from 60)
        const piece_timeout_ms = 45 * 1000; // 45 seconds timeout for piece progress (increased from 30)
        var consecutive_errors: u8 = 0;
        var blocks_received: usize = 0;
        var last_blocks_received: usize = 0;
        var sent_requests: usize = 0;

        // Send initial interested message (ensure we're registered as interested)
        peer.sendMessage(.interested) catch |err| {
            debug.print("Failed to send initial interested message: {}\n", .{err});
        };
        has_sent_interested = true;
        debug.print("Initial 'interested' message sent to peer, waiting for 'unchoke'...\n", .{});

        while (!self.piece_manager.isDownloadComplete()) {
            // Check for timeout
            const current_time = std.time.milliTimestamp();

            // Global timeout check
            if (current_time - last_message_time > timeout_ms) {
                debug.print("Peer connection timed out after {} seconds\n", .{timeout_ms / 1000});
                break;
            }

            // Check for piece download progress (stalled download)
            if (!is_choked and current_piece != null) {
                if (current_time - last_piece_progress_time > piece_timeout_ms and
                    blocks_received == last_blocks_received and
                    sent_requests > 0)
                {
                    debug.print("Piece {} download stalled for {} seconds, requesting a different piece\n", .{ current_piece.?, piece_timeout_ms / 1000 });

                    // Reset the piece request counters
                    sent_requests = 0;
                    blocks_received = 0;
                    last_blocks_received = 0;

                    // Get a different piece
                    current_piece = self.piece_manager.getNextNeededPiece();
                    if (current_piece) |piece_index| {
                        debug.print("Trying different piece: {}\n", .{piece_index});
                        self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                            debug.print("Failed to request new piece: {}\n", .{err});
                            current_piece = null;
                        };
                    }

                    last_piece_progress_time = current_time;
                }
            }

            // Set timeouts on the socket - longer timeout to avoid premature disconnections
            peer.setReadTimeout(10 * 1000) catch |err| {
                debug.print("Failed to set socket read timeout: {}\n", .{err});
            };
            peer.setWriteTimeout(10 * 1000) catch |err| {
                debug.print("Failed to set socket write timeout: {}\n", .{err});
            };

            var message = peer.readMessage() catch |err| {
                if (err == error.WouldBlock or err == error.TimedOut) {
                    // Only send keep-alive if we haven't sent anything recently
                    if (current_time - last_message_time > 30000) { // 30 seconds
                        debug.print("No message for 30 seconds, sending keep-alive...\n", .{});
                        peer.sendMessage(.keep_alive) catch {};
                    }

                    // If we're still choked, resend interested message periodically
                    if (is_choked and current_time - last_message_time > 15000) {
                        debug.print("Still choked after 15 seconds, resending interested message...\n", .{});
                        peer.sendMessage(.interested) catch {};
                        has_sent_interested = true;
                        last_message_time = current_time; // Reset timer
                    }

                    // If we're unchoked but no piece progress, try requesting pieces again
                    if (!is_choked and current_piece != null and
                        current_time - last_piece_progress_time > 10000 and // 10 seconds with no progress
                        blocks_received == last_blocks_received)
                    {
                        debug.print("No block progress for 10 seconds, re-requesting blocks for piece {}...\n", .{current_piece.?});

                        self.piece_manager.requestPiece(peer, current_piece.?) catch |request_err| {
                            debug.print("Failed to re-request piece: {}\n", .{request_err});
                        };

                        sent_requests += 1;
                    }

                    consecutive_errors = 0;
                    std.time.sleep(500 * std.time.ns_per_ms); // 500ms wait before retry
                    continue;
                }

                consecutive_errors += 1;
                debug.print("Error reading message from peer: {} (attempt {}/5)\n", .{ err, consecutive_errors });

                if (consecutive_errors >= 5) {
                    debug.print("Too many consecutive errors, disconnecting peer\n", .{});
                    break;
                }

                // Brief pause before retrying
                std.time.sleep(1_000_000_000); // 1 second
                continue;
            };
            defer message.deinit(self.allocator);

            // Reset error counter since we got a successful message
            consecutive_errors = 0;

            // Update last message time
            last_message_time = current_time;

            switch (message) {
                .unchoke => {
                    debug.print("DOWNLOAD STATUS: Peer unchoked us - now able to request pieces\n", .{});

                    // Only log state transition if we were previously choked
                    if (is_choked) {
                        debug.print("DOWNLOAD STATE: Transitioned from CHOKED to UNCHOKED state\n", .{});
                    }

                    is_choked = false;
                    last_piece_progress_time = current_time;

                    // Request a piece if we don't have one in progress
                    if (current_piece == null) {
                        // First try pieces that this peer has
                        var found_piece = false;

                        if (peer_has_pieces.items.len > 0) {
                            // Use a random selection from the peer's pieces for better distribution
                            var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
                            const random = rng.random();

                            const tries = @min(10, peer_has_pieces.items.len); // Try up to 10 random pieces
                            var i: usize = 0;
                            while (i < tries) : (i += 1) {
                                const random_index = random.intRangeLessThan(usize, 0, peer_has_pieces.items.len);
                                const candidate_piece = peer_has_pieces.items[random_index];

                                if (!self.piece_manager.hasPiece(candidate_piece)) {
                                    current_piece = candidate_piece;
                                    debug.print("DOWNLOAD INITIAL: Requesting piece {} (peer has it)\n", .{candidate_piece});
                                    self.piece_manager.requestPiece(peer, candidate_piece) catch |err| {
                                        debug.print("Failed to request piece: {}\n", .{err});
                                        current_piece = null;
                                        continue;
                                    };
                                    found_piece = true;
                                    sent_requests += 1;
                                    break;
                                }
                            }
                        }

                        // If we couldn't find a piece the peer has, get any needed piece
                        if (!found_piece) {
                            current_piece = self.piece_manager.getNextNeededPiece();
                            if (current_piece) |piece_index| {
                                debug.print("DOWNLOAD INITIAL: Requesting first piece {}\n", .{piece_index});
                                self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                    debug.print("Failed to request piece: {}\n", .{err});
                                    current_piece = null;
                                };
                                sent_requests += 1;
                            } else {
                                debug.print("DOWNLOAD COMPLETE: No more pieces needed\n", .{});
                            }
                        }
                    }
                },
                .piece => |piece| {
                    debug.print("DOWNLOAD PROGRESS: Received block for piece {} (offset: {}, size: {})\n", .{ piece.index, piece.begin, piece.block.len });

                    // Update block counters
                    blocks_received += 1;
                    last_piece_progress_time = current_time;

                    try self.file_io.writeBlock(piece.index, piece.begin, piece.block);
                    self.piece_manager.markBlockReceived(piece.index, piece.begin, piece.block);

                    // Record downloaded bytes in metrics
                    if (self.metrics) |metrics| {
                        metrics.recordBytesDownloaded(piece.block.len);
                        try metrics.updateDownloadRate();
                    }

                    // If we've completed the current piece, request another one
                    if (current_piece != null and self.piece_manager.hasPiece(current_piece.?)) {
                        debug.print("DOWNLOAD PROGRESS: Piece {} completed, moving to next piece\n", .{current_piece.?});

                        // Reset counters for the new piece
                        blocks_received = 0;
                        last_blocks_received = 0;
                        sent_requests = 0;

                        // Try to find a piece this peer has that we need
                        var found_piece = false;
                        if (peer_has_pieces.items.len > 0) {
                            var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
                            const random = rng.random();

                            const tries = @min(10, peer_has_pieces.items.len);
                            var i: usize = 0;
                            while (i < tries) : (i += 1) {
                                const random_index = random.intRangeLessThan(usize, 0, peer_has_pieces.items.len);
                                const candidate_piece = peer_has_pieces.items[random_index];

                                if (!self.piece_manager.hasPiece(candidate_piece)) {
                                    current_piece = candidate_piece;
                                    debug.print("DOWNLOAD PROGRESS: Requesting piece {} (peer has it)\n", .{candidate_piece});
                                    self.piece_manager.requestPiece(peer, candidate_piece) catch |err| {
                                        debug.print("Failed to request piece: {}\n", .{err});
                                        current_piece = null;
                                        continue;
                                    };
                                    found_piece = true;
                                    sent_requests += 1;
                                    break;
                                }
                            }
                        }

                        // Fall back to any needed piece
                        if (!found_piece) {
                            current_piece = self.piece_manager.getNextNeededPiece();
                            if (current_piece) |piece_index| {
                                debug.print("DOWNLOAD PROGRESS: Requesting next piece {}\n", .{piece_index});
                                self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                    debug.print("Failed to request piece: {}\n", .{err});
                                    current_piece = null;
                                };
                                sent_requests += 1;
                            }
                        }
                    }
                    // If this is a piece we're actively downloading, track block reception
                    else if (current_piece != null and piece.index == current_piece.?) {
                        last_blocks_received = blocks_received;
                    }
                    // If we got a block for a different piece than the one we're tracking
                    else if (current_piece != null and piece.index != current_piece.?) {
                        debug.print("Received block for piece {} but tracking piece {}\n", .{ piece.index, current_piece.? });
                    }
                },
                .choke => {
                    debug.print("DOWNLOAD STATE: Peer choked us - can't request pieces until unchoked\n", .{});
                    is_choked = true;

                    // We can't request more blocks for now, but we don't reset current_piece
                    // This allows us to track the piece we were working on before being choked

                    // Reset the request counters
                    sent_requests = 0;
                },
                .interested => {
                    debug.print("Peer is interested\n", .{});
                },
                .not_interested => {
                    debug.print("Peer is not interested\n", .{});
                },
                .have => |piece_index| {
                    debug.print("Peer has piece {}\n", .{piece_index});
                    try peer_has_pieces.append(piece_index);

                    // If we're not choked and don't have a current piece, request this one
                    if (!is_choked and current_piece == null and
                        !self.piece_manager.hasPiece(piece_index))
                    {
                        current_piece = piece_index;
                        self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                            debug.print("Failed to request piece: {}\n", .{err});
                            current_piece = null;
                        };
                    }
                },
                .bitfield => |bitfield| {
                    debug.print("Received peer bitfield of length {}\n", .{bitfield.len});

                    // Parse the bitfield to see which pieces the peer has
                    for (0..self.piece_manager.total_pieces) |i| {
                        const byte_index = i / 8;
                        if (byte_index >= bitfield.len) break;

                        const bit_index = 7 - @as(u3, @intCast(i % 8)); // MSB first in BitTorrent protocol
                        const has_piece = (bitfield[byte_index] & (@as(u8, 1) << bit_index)) != 0;

                        if (has_piece) {
                            try peer_has_pieces.append(i);
                        }
                    }

                    debug.print("Peer has {} pieces\n", .{peer_has_pieces.items.len});

                    // If we're not choked, request a piece
                    if (!is_choked and current_piece == null) {
                        // First try to find a piece this peer has that we need
                        for (peer_has_pieces.items) |piece_index| {
                            if (!self.piece_manager.hasPiece(piece_index)) {
                                current_piece = piece_index;
                                self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                    debug.print("Failed to request piece: {}\n", .{err});
                                    current_piece = null;
                                    continue;
                                };
                                break;
                            }
                        }

                        // If we couldn't find a specific piece, just get the next needed one
                        if (current_piece == null) {
                            current_piece = self.piece_manager.getNextNeededPiece();
                            if (current_piece) |piece_index| {
                                debug.print("Requesting piece {}\n", .{piece_index});
                                self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                    debug.print("Failed to request piece: {}\n", .{err});
                                    current_piece = null;
                                };
                            }
                        }
                    }
                },
                .keep_alive => {
                    debug.print("Received keep-alive message\n", .{});
                },
                else => {
                    debug.print("Received other message type\n", .{});
                },
            }

            // If we're not choked and don't have a current piece, try to get one
            if (!is_choked and current_piece == null) {
                current_piece = self.piece_manager.getNextNeededPiece();
                if (current_piece) |piece_index| {
                    debug.print("Requesting piece {}\n", .{piece_index});
                    self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                        debug.print("Failed to request piece: {}\n", .{err});
                        current_piece = null;
                    };
                }
            } else if (is_choked and !has_sent_interested) {
                // If we're still choked and haven't sent interested, send it now
                debug.print("Still choked, sending interested message...\n", .{});
                peer.sendMessage(.interested) catch |err| {
                    debug.print("Failed to send interested message: {}\n", .{err});
                };
                has_sent_interested = true;
            }
        }
        debug.print("Download complete for this peer\n", .{});
    }

    // Print current metrics
    pub fn printMetrics(self: *PeerManager) void {
        if (self.metrics) |metrics| {
            metrics.printMetrics();
        }
    }
};

// Helper to parse compact peer list from tracker response
pub fn parseCompactPeers(allocator: Allocator, data: []const u8) ![]net.Address {
    var peers = std.ArrayList(net.Address).init(allocator);
    errdefer peers.deinit();

    var i: usize = 0;
    while (i + 6 <= data.len) : (i += 6) {
        const ip_bytes = data[i..][0..4].*;
        const port = std.mem.readInt(u16, data[i + 4 ..][0..2], .big);
        const address = net.Address.initIp4(ip_bytes, port);
        try peers.append(address);
    }

    return peers.toOwnedSlice();
}
