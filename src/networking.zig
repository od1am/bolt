const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const linux = os.linux;
const net = std.net;
const Allocator = std.mem.Allocator;
const PeerConnection = @import("peer_wire.zig").PeerConnection;
const PieceManager = @import("piece_manager.zig").PieceManager;
const FileIO = @import("file_io.zig").FileIO;
const TorrentFile = @import("torrent.zig").TorrentFile;

// PeerManager coordinates connections to multiple peers
pub const PeerManager = struct {
    allocator: Allocator,
    torrent_file: TorrentFile,
    piece_manager: *PieceManager,
    file_io: *FileIO,
    peers: std.ArrayList(PeerConnection),
    peer_id: [20]u8,
    info_hash: [20]u8,

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
            .peers = std.ArrayList(PeerConnection).init(allocator),
            .peer_id = peer_id,
            .info_hash = info_hash,
        };
    }

    pub fn deinit(self: *PeerManager) void {
        for (self.peers.items) |*peer| {
            peer.deinit();
        }
        self.peers.deinit();
    }

    // Connect to a peer and add it to the list
    pub fn connectToPeer(self: *PeerManager, address: net.Address) !void {
        var ip_buf: [100]u8 = undefined;
        const ip = try std.fmt.bufPrint(&ip_buf, "{}", .{address});

        std.debug.print("Attempting to connect to peer {s}\n", .{ip});

        // Create a socket
        const socket = try std.net.tcpConnectToAddress(address);
        errdefer socket.close();

        // Use a connection timeout with epoll
        if (builtin.os.tag == .linux) {
            // Create epoll instance
            const epfd = os.linux.epoll_create1(0);
            defer os.close(epfd);

            // Set socket to non-blocking mode
            try linux.fcntl(socket.handle, linux.F_SETFL, try linux.fcntl(socket.handle, linux.F_GETFL, 0) | linux.O.NONBLOCK);

            // Add socket to epoll
            var event = os.linux.epoll_event{
                .events = os.linux.EPOLL.OUT | os.linux.EPOLL.ERR,
                .data = .{ .fd = socket.handle },
            };
            try os.linux.epoll_ctl(epfd, os.linux.EPOLL.CTL_ADD, socket.handle, &event);

            // Wait for connection with timeout
            var events: [1]os.linux.epoll_event = undefined;
            const timeout_ms = 5000; // 5 seconds
            const num_events = try os.linux.epoll_wait(epfd, &events, timeout_ms);

            if (num_events == 0) {
                std.debug.print("Connection timeout for peer {s}\n", .{ip});
                return error.ConnectionTimeout;
            }

            if ((events[0].events & os.linux.EPOLL.ERR) != 0) {
                std.debug.print("Connection error for peer {s}\n", .{ip});
                return error.ConnectionFailed;
            }

            // Set socket back to blocking mode
            try linux.fcntl(socket.handle, linux.F_SETFL, try linux.fcntl(socket.handle, linux.F_GETFL, 0) & ~linux.O.NONBLOCK);
        } else {
            // Fallback for non-Linux platforms
            // Set a reasonable timeout on the socket directly
            try socket.setOption(.send_timeout, 5000); // 5 second timeout
            try socket.setOption(.recv_timeout, 5000); // 5 second timeout
        }

        // Set socket options for better performance
        if (@hasDecl(std.os, "TCP_NODELAY")) {
            std.debug.print("Setting TCP_NODELAY option...\n", .{});
            socket.setOption(.tcp_nodelay, true) catch |err| {
                std.debug.print("Failed to set TCP_NODELAY: {}\n", .{err});
            };
        }

        var peer = PeerConnection{
            .socket = socket,
            .peer_id = self.peer_id,
            .info_hash = self.info_hash,
            .allocator = self.allocator,
        };

        std.debug.print("Performing handshake with peer...\n", .{});
        peer.handshake() catch |err| {
            std.debug.print("Handshake failed with peer {s}: {}\n", .{ ip, err });
            peer.deinit();
            return err;
        };

        try self.peers.append(peer);
        std.debug.print("Successfully connected to peer {s}\n", .{ip});
    }

    // Start downloading pieces from all connected peers
    pub fn startDownload(self: *PeerManager) !void {
        std.debug.print("Starting download with {} connected peers\n", .{self.peers.items.len});

        for (self.peers.items) |*peer| {
            std.debug.print("Sending interested message to peer\n", .{});
            try peer.sendMessage(.interested);

            const thread = try std.Thread.spawn(.{}, handlePeer, .{ self, peer });
            thread.detach();
        }
    }

    // Handle messages from a single peer (runs in a separate thread)
    fn handlePeer(self: *PeerManager, peer: *PeerConnection) !void {
        defer peer.deinit();
        var peer_has_pieces = std.ArrayList(usize).init(self.allocator);
        defer peer_has_pieces.deinit();

        var is_choked = true;
        var current_piece: ?usize = null;
        var last_message_time = std.time.milliTimestamp();
        const timeout_ms = 60 * 1000; // 60 seconds timeout

        while (!self.piece_manager.isDownloadComplete()) {
            // Check for timeout
            const current_time = std.time.milliTimestamp();
            if (current_time - last_message_time > timeout_ms) {
                std.debug.print("Peer connection timed out after {} seconds\n", .{timeout_ms / 1000});
                break;
            }

            // Set a read timeout on the socket
            peer.setReadTimeout(5 * 1000) catch |err| {
                std.debug.print("Failed to set socket timeout: {}\n", .{err});
            };

            var message = peer.readMessage() catch |err| {
                if (err == error.WouldBlock or err == error.TimedOut) {
                    // Send keep-alive to keep the connection active
                    peer.sendMessage(.keep_alive) catch {};
                    continue;
                }
                std.debug.print("Error reading message from peer: {}\n", .{err});
                break;
            };
            defer message.deinit(self.allocator);

            // Update last message time
            last_message_time = std.time.milliTimestamp();

            switch (message) {
                .unchoke => {
                    std.debug.print("Peer unchoked us - requesting pieces\n", .{});
                    is_choked = false;

                    // Request a piece if we don't have one in progress
                    if (current_piece == null) {
                        current_piece = self.piece_manager.getNextNeededPiece();
                        if (current_piece) |piece_index| {
                            std.debug.print("Requesting piece {}\n", .{piece_index});
                            self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                std.debug.print("Failed to request piece: {}\n", .{err});
                                current_piece = null;
                            };
                        }
                    }
                },
                .piece => |piece| {
                    std.debug.print("Received piece {} (offset: {}, size: {})\n", .{ piece.index, piece.begin, piece.block.len });

                    try self.file_io.writeBlock(piece.index, piece.begin, piece.block);
                    self.piece_manager.markBlockReceived(piece.index, piece.begin, piece.block);

                    // If we've completed the current piece, request another one
                    if (current_piece != null and self.piece_manager.hasPiece(current_piece.?)) {
                        current_piece = self.piece_manager.getNextNeededPiece();
                        if (current_piece) |piece_index| {
                            std.debug.print("Requesting next piece {}\n", .{piece_index});
                            self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                std.debug.print("Failed to request piece: {}\n", .{err});
                                current_piece = null;
                            };
                        }
                    }
                },
                .choke => {
                    std.debug.print("Peer choked us\n", .{});
                    is_choked = true;
                    current_piece = null;
                },
                .interested => {
                    std.debug.print("Peer is interested\n", .{});
                },
                .not_interested => {
                    std.debug.print("Peer is not interested\n", .{});
                },
                .have => |piece_index| {
                    std.debug.print("Peer has piece {}\n", .{piece_index});
                    try peer_has_pieces.append(piece_index);

                    // If we're not choked and don't have a current piece, request this one
                    if (!is_choked and current_piece == null and
                        !self.piece_manager.hasPiece(piece_index))
                    {
                        current_piece = piece_index;
                        self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                            std.debug.print("Failed to request piece: {}\n", .{err});
                            current_piece = null;
                        };
                    }
                },
                .bitfield => |bitfield| {
                    std.debug.print("Received peer bitfield of length {}\n", .{bitfield.len});

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

                    std.debug.print("Peer has {} pieces\n", .{peer_has_pieces.items.len});

                    // If we're not choked, request a piece
                    if (!is_choked and current_piece == null) {
                        // First try to find a piece this peer has that we need
                        for (peer_has_pieces.items) |piece_index| {
                            if (!self.piece_manager.hasPiece(piece_index)) {
                                current_piece = piece_index;
                                self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                    std.debug.print("Failed to request piece: {}\n", .{err});
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
                                std.debug.print("Requesting piece {}\n", .{piece_index});
                                self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                                    std.debug.print("Failed to request piece: {}\n", .{err});
                                    current_piece = null;
                                };
                            }
                        }
                    }
                },
                .keep_alive => {
                    std.debug.print("Received keep-alive message\n", .{});
                },
                else => {
                    std.debug.print("Received other message type\n", .{});
                },
            }

            // If we're not choked and don't have a current piece, try to get one
            if (!is_choked and current_piece == null) {
                current_piece = self.piece_manager.getNextNeededPiece();
                if (current_piece) |piece_index| {
                    std.debug.print("Requesting piece {}\n", .{piece_index});
                    self.piece_manager.requestPiece(peer, piece_index) catch |err| {
                        std.debug.print("Failed to request piece: {}\n", .{err});
                        current_piece = null;
                    };
                }
            }
        }
        std.debug.print("Download complete for this peer\n", .{});
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
