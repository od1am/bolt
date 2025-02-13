const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

// Peer Wire Protocol message types
pub const MessageType = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    not_interested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,
    keep_alive = 255, // Special case for keep-alive messages
};

// Peer Wire Protocol message structure
pub const PeerMessage = union(enum) {
    choke: void,
    unchoke: void,
    interested: void,
    not_interested: void,
    have: u32, // Piece index
    bitfield: []const u8, // Bitfield of available pieces
    request: struct { index: u32, begin: u32, length: u32 }, // Request a block
    piece: struct { index: u32, begin: u32, block: []const u8 }, // Data block
    cancel: struct { index: u32, begin: u32, length: u32 }, // Cancel a request
    keep_alive: void,

    pub fn deinit(self: *PeerMessage, allocator: Allocator) void {
        switch (self.*) {
            .bitfield => |bf| allocator.free(bf),
            .piece => |p| allocator.free(p.block),
            else => {},
        }
    }
};

// Peer connection state
pub const PeerConnection = struct {
    socket: net.Stream,
    peer_id: [20]u8,
    info_hash: [20]u8,
    allocator: Allocator,

    pub fn deinit(self: *PeerConnection) void {
        self.socket.close();
    }

    // Perform the handshake with the peer
    pub fn handshake(self: *PeerConnection) !void {
        var handshake_buffer: [68]u8 = undefined;
        handshake_buffer[0] = 19; // Protocol identifier length
        @memcpy(handshake_buffer[1..20], "BitTorrent protocol"); // Protocol identifier
        std.mem.set(u8, handshake_buffer[20..28], 0); // Reserved bytes
        @memcpy(handshake_buffer[28..48], &self.info_hash); // Info hash
        @memcpy(handshake_buffer[48..68], &self.peer_id); // Peer ID

        try self.socket.writeAll(&handshake_buffer);

        var response: [68]u8 = undefined;
        const bytes_read = try self.socket.readAll(&response);
        if (bytes_read != 68) return error.HandshakeFailed;

        // Verify the response
        if (!std.mem.eql(u8, response[1..20], "BitTorrent protocol")) return error.HandshakeFailed;
        if (!std.mem.eql(u8, response[28..48], &self.info_hash)) return error.HandshakeFailed;
    }

    // Read a message from the peer
    pub fn readMessage(self: *PeerConnection) !PeerMessage {
        var length_buf: [4]u8 = undefined;
        const bytes_read = try self.socket.read(&length_buf);
        if (bytes_read != 4) return error.ConnectionClosed;

        const length = std.mem.readInt(u32, &length_buf, .big);
        if (length == 0) return .keep_alive;

        var message_buf = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(message_buf);

        const msg_bytes_read = try self.socket.read(message_buf);
        if (msg_bytes_read != length) return error.ConnectionClosed;

        const message_type: MessageType = @enumFromInt(message_buf[0]);
        const payload = message_buf[1..];

        switch (message_type) {
            .choke => return PeerMessage{ .choke = {} },
            .unchoke => return PeerMessage{ .unchoke = {} },
            .interested => return PeerMessage{ .interested = {} },
            .not_interested => return PeerMessage{ .not_interested = {} },
            .have => {
                if (payload.len != 4) return error.InvalidMessage;
                const piece_index = std.mem.readInt(u32, payload[0..4], .big);
                return PeerMessage{ .have = piece_index };
            },
            .bitfield => {
                const bitfield = try self.allocator.dupe(u8, payload);
                return PeerMessage{ .bitfield = bitfield };
            },
            .piece => {
                if (payload.len < 8) return error.InvalidMessage;
                const index = std.mem.readInt(u32, payload[0..4], .big);
                const begin = std.mem.readInt(u32, payload[4..8], .big);
                const block = try self.allocator.dupe(u8, payload[8..]);
                return PeerMessage{ .piece = .{ .index = index, .begin = begin, .block = block } };
            },
            .request => {
                if (payload.len != 12) return error.InvalidMessage;
                const index = std.mem.readInt(u32, payload[0..4], .big);
                const begin = std.mem.readInt(u32, payload[4..8], .big);
                const req_length = std.mem.readInt(u32, payload[8..12], .big);
                return PeerMessage{ .request = .{ .index = index, .begin = begin, .length = req_length } };
            },
            .cancel => {
                if (payload.len != 12) return error.InvalidMessage;
                const index = std.mem.readInt(u32, payload[0..4], .big);
                const begin = std.mem.readInt(u32, payload[4..8], .big);
                const req_length = std.mem.readInt(u32, payload[8..12], .big);
                return PeerMessage{ .cancel = .{ .index = index, .begin = begin, .length = req_length } };
            },
            else => return error.InvalidMessage,
        }
    }

    // Send a message to the peer
    pub fn sendMessage(self: *PeerConnection, message: PeerMessage) !void {
        switch (message) {
            .choke => try self.sendMessageType(.choke),
            .unchoke => try self.sendMessageType(.unchoke),
            .interested => try self.sendMessageType(.interested),
            .not_interested => try self.sendMessageType(.not_interested),
            .have => |piece_index| {
                var buf: [5]u8 = undefined;
                buf[0] = @intFromEnum(MessageType.have);
                std.mem.writeInt(u32, buf[1..5], piece_index, .big);
                try self.sendMessageBuffer(&buf);
            },
            .bitfield => |bitfield| {
                var buf = try self.allocator.alloc(u8, 1 + bitfield.len);
                defer self.allocator.free(buf);
                buf[0] = @intFromEnum(MessageType.bitfield);
                @memcpy(buf[1..], bitfield);
                try self.sendMessageBuffer(buf);
            },
            .request => |req| {
                var buf: [13]u8 = undefined;
                buf[0] = @intFromEnum(MessageType.request);
                std.mem.writeInt(u32, buf[1..5], req.index, .big);
                std.mem.writeInt(u32, buf[5..9], req.begin, .big);
                std.mem.writeInt(u32, buf[9..13], req.length, .big);
                try self.sendMessageBuffer(&buf);
            },
            .piece => |p| {
                var buf = try self.allocator.alloc(u8, 9 + p.block.len);
                defer self.allocator.free(buf);
                buf[0] = @intFromEnum(MessageType.piece);
                std.mem.writeInt(u32, buf[1..5], p.index, .big);
                std.mem.writeInt(u32, buf[5..9], p.begin, .big);
                @memcpy(buf[9..], p.block);
                try self.sendMessageBuffer(buf);
            },
            .cancel => |c| {
                var buf: [13]u8 = undefined;
                buf[0] = @intFromEnum(MessageType.cancel);
                std.mem.writeInt(u32, buf[1..5], c.index, .big);
                std.mem.writeInt(u32, buf[5..9], c.begin, .big);
                std.mem.writeInt(u32, buf[9..13], c.length, .big);
                try self.sendMessageBuffer(&buf);
            },
            .keep_alive => {
                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, 0, .big);
                try self.socket.writeAll(&buf);
            },
        }
    }

    // Helper function to send a message type without payload
    fn sendMessageType(self: *PeerConnection, message_type: MessageType) !void {
        var buf: [5]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 1, .big); // Length prefix
        buf[4] = @intFromEnum(message_type);
        try self.socket.writeAll(&buf);
    }

    // Helper function to send a message buffer
    fn sendMessageBuffer(self: *PeerConnection, buffer: []const u8) !void {
        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, @intCast(buffer.len), .big);
        try self.socket.writeAll(&length_buf);
        try self.socket.writeAll(buffer);
    }
};
