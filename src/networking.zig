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

// Optional local address to bind outgoing connections to
var local_address: ?net.Address = null;

// Function to set the local address for outgoing connections
pub fn setLocalAddress(address_str: []const u8, port: u16) !void {
    local_address = try net.Address.parseIp(address_str, port);
    debug.print("Local address set to {}:{}\n", .{ address_str, port });
}

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

    pub fn init(
        allocator: Allocator,
        torrent_file: TorrentFile,
        piece_manager: *PieceManager,
        file_io: *FileIO,
        peer_id: [20]u8,
        info_hash: [20]u8,
    ) PeerManager {
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
        };
    }

    pub fn deinit(self: *PeerManager) void {
        for (self.peers.items) |*peer| {
            peer.deinit();
        }
        self.peers.deinit();
    }

    pub fn getActivePeerCount(self: *PeerManager) usize {
        return self.active_peers.load(.acquire);
    }

    // Connect to a peer and add it to the list
    pub fn connectToPeer(self: *PeerManager, address: net.Address) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ip_buf: [100]u8 = undefined;
        const ip = try std.fmt.bufPrint(&ip_buf, "{}", .{address});

        debug.print("Attempting to connect to peer {s}\n", .{ip});

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
            }

            // Bind to the local address
            try posix.bind(sock, &local_addr.any, local_addr.getOsSockLen());

            // Connect to the peer
            try posix.connect(sock, &address.any, address.getOsSockLen());

            break :blk std.net.Stream{ .handle = sock };
        } else std.net.tcpConnectToAddress(address) catch |err| {
            debug.print("Failed to connect to peer {s}: {}\n", .{ ip, err });
            return err;
        };
        errdefer {
            // Safely close the socket - in Zig 0.13 std.net.Stream.close() also returns void
            socket.close();
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

            return err;
        };

        try self.peers.append(peer);
        debug.print("Successfully connected to peer {s}\n", .{ip});
    }

    // Start downloading pieces from all connected peers
    pub fn startDownload(self: *PeerManager) !void {
        debug.print("Starting download with {} connected peers\n", .{self.peers.items.len});

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.peers.items) |*peer| {
            debug.print("Sending interested message to peer\n", .{});
            try peer.sendMessage(.interested);

            const thread = try std.Thread.spawn(.{}, handlePeer, .{ self, peer });
            thread.detach();
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

        const thread = try std.Thread.spawn(.{}, handlePeer, .{ self, peer });
        thread.detach();
    }

    // Handle messages from a single peer (runs in a separate thread)
    fn handlePeer(self: *PeerManager, peer: *PeerConnection) !void {
        _ = self.active_peers.fetchAdd(1, .acq_rel);
        defer {
            _ = self.active_peers.fetchSub(1, .acq_rel);
            debug.print("Peer disconnected, active peers: {}\n", .{self.active_peers.load(.acquire)});
        }

        defer peer.deinit();
        var peer_has_pieces = std.ArrayList(usize).init(self.allocator);
        defer peer_has_pieces.deinit();

        var is_choked = true;
        var has_sent_interested = false;
        var current_piece: ?usize = null;
        var last_message_time = std.time.milliTimestamp();
        const timeout_ms = 60 * 1000; // 60 seconds timeout
        var consecutive_errors: u8 = 0;

        // Send initial interested message (ensure we're registered as interested)
        peer.sendMessage(.interested) catch |err| {
            debug.print("Failed to send initial interested message: {}\n", .{err});
        };
        has_sent_interested = true;
        debug.print("Initial 'interested' message sent to peer, waiting for 'unchoke'...\n", .{});

        while (!self.piece_manager.isDownloadComplete()) {
            // Check for timeout
            const current_time = std.time.milliTimestamp();
            if (current_time - last_message_time > timeout_ms) {
                debug.print("Peer connection timed out after {} seconds\n", .{timeout_ms / 1000});
                break;
            }

            // Set a read timeout on the socket
            peer.setReadTimeout(5 * 1000) catch |err| {
                debug.print("Failed to set socket timeout: {}\n", .{err});
            };

            var message = peer.readMessage() catch |err| {
                if (err == error.WouldBlock or err == error.TimedOut) {
                    // Send keep-alive to keep the connection active
                    debug.print("No message received in 5 seconds, sending keep-alive...\n", .{});
                    peer.sendMessage(.keep_alive) catch {};

                    // If we're still choked, resend interested message periodically
                    if (is_choked and current_time - last_message_time > 15000) {
                        debug.print("Still choked after 15 seconds, resending interested message...\n", .{});
                        peer.sendMessage(.interested) catch {};
                        last_message_time = current_time; // Reset timer
                    }

                    consecutive_errors = 0;
                    continue;
                }

                consecutive_errors += 1;
                debug.print("Error reading message from peer: {} (attempt {}/3)\n", .{ err, consecutive_errors });

                if (consecutive_errors >= 3) {
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
            last_message_time = std.time.milliTimestamp();

            switch (message) {
                .unchoke => {
                    debug.print("DOWNLOAD STATUS: Peer unchoked us - now able to request pieces\n", .{});

                    // Only log state transition if we were previously choked
                    if (is_choked) {
                        debug.print("DOWNLOAD STATE: Transitioned from CHOKED to UNCHOKED state\n", .{});
                    }

                    is_choked = false;

                    // Request a piece if we don't have one in progress
                    if (current_piece == null) {
                        current_piece = self.piece_manager.getNextNeededPiece();
                        if (current_piece) |piece_index| {
                            debug.print("DOWNLOAD INITIAL: Requesting first piece {}\n", .{piece_index});
                            self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                debug.print("Failed to request piece: {}\n", .{err});
                                current_piece = null;
                            };
                        } else {
                            debug.print("DOWNLOAD COMPLETE: No more pieces needed\n", .{});
                        }
                    }
                },
                .piece => |piece| {
                    debug.print("DOWNLOAD PROGRESS: Received block for piece {} (offset: {}, size: {})\n", .{ piece.index, piece.begin, piece.block.len });

                    try self.file_io.writeBlock(piece.index, piece.begin, piece.block);
                    self.piece_manager.markBlockReceived(piece.index, piece.begin, piece.block);

                    // If we've completed the current piece, request another one
                    if (current_piece != null and self.piece_manager.hasPiece(current_piece.?)) {
                        debug.print("DOWNLOAD PROGRESS: Piece {} completed, moving to next piece\n", .{current_piece.?});
                        current_piece = self.piece_manager.getNextNeededPiece();
                        if (current_piece) |piece_index| {
                            debug.print("DOWNLOAD PROGRESS: Requesting next piece {}\n", .{piece_index});
                            self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                debug.print("Failed to request piece: {}\n", .{err});
                                current_piece = null;
                            };
                        }
                    }
                },
                .choke => {
                    debug.print("DOWNLOAD STATE: Peer choked us - can't request pieces until unchoked\n", .{});
                    is_choked = true;
                    current_piece = null;
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
