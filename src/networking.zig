const std = @import("std");
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

        const socket = try net.tcpConnectToAddress(address);
        errdefer socket.close();

        var peer = PeerConnection{
            .socket = socket,
            .peer_id = self.peer_id,
            .info_hash = self.info_hash,
            .allocator = self.allocator,
        };

        std.debug.print("Performing handshake with peer...\n", .{});
        try peer.handshake();
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

        while (!self.piece_manager.isDownloadComplete()) {
            var message = try peer.readMessage();
            defer message.deinit(self.allocator);

            switch (message) {
                .unchoke => {
                    std.debug.print("Peer unchoked us - requesting pieces\n", .{});
                    const next_piece = self.piece_manager.getNextNeededPiece();
                    if (next_piece) |piece_index| {
                        std.debug.print("Requesting piece {}\n", .{piece_index});
                        try self.piece_manager.requestPiece(peer, piece_index);
                    } else {
                        std.debug.print("No more pieces needed\n", .{});
                    }
                },
                .piece => |piece| {
                    std.debug.print("Received piece {} (offset: {}, size: {})\n", .{ piece.index, piece.begin, piece.block.len });

                    try self.file_io.writeBlock(piece.index, piece.begin, piece.block);
                    self.piece_manager.markBlockReceived(piece.index, piece.begin, piece.block.len);

                    const next_piece = self.piece_manager.getNextNeededPiece();
                    if (next_piece) |piece_index| {
                        std.debug.print("Requesting next piece {}\n", .{piece_index});
                        try self.piece_manager.requestPiece(peer, piece_index);
                    } else {
                        std.debug.print("No more pieces needed\n", .{});
                    }
                },
                .choke => {
                    std.debug.print("Peer choked us\n", .{});
                },
                .interested => {
                    std.debug.print("Peer is interested\n", .{});
                },
                .not_interested => {
                    std.debug.print("Peer is not interested\n", .{});
                },
                .have => |piece_index| {
                    std.debug.print("Peer has piece {}\n", .{piece_index});
                },
                .bitfield => {
                    std.debug.print("Received peer bitfield\n", .{});
                },
                else => {
                    std.debug.print("Received other message type\n", .{});
                },
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
    while (i + 6 <= data.len) {
        const ip = data[i..][0..4];
        const port = std.mem.readInt(u16, data[i + 4 ..][0..2], .big);
        const address = try net.Address.parseIp4(ip, port);
        try peers.append(address);
        i += 6;
    }

    return peers.toOwnedSlice();
}
