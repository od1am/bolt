const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

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
    keep_alive = 255,
};

pub const PeerMessage = union(enum) {
    choke: void,
    unchoke: void,
    interested: void,
    not_interested: void,
    have: u32,
    bitfield: []const u8,
    request: struct { index: u32, begin: u32, length: u32 },
    piece: struct { index: u32, begin: u32, block: []const u8 },
    cancel: struct { index: u32, begin: u32, length: u32 },
    keep_alive: void,

    pub fn deinit(self: *PeerMessage, allocator: Allocator) void {
        switch (self.*) {
            .bitfield => |bf| allocator.free(bf),
            .piece => |p| allocator.free(p.block),
            else => {},
        }
    }
};

pub const PeerConnection = struct {
    socket: net.Stream,
    peer_id: [20]u8,
    info_hash: [20]u8,
    allocator: Allocator,

    pub fn deinit(self: *PeerConnection) void {
        // Close the socket and ignore any errors that might occur
        self.socket.close();
    }

    pub fn setReadTimeout(self: *PeerConnection, milliseconds: u32) !void {
        if (@hasDecl(std.os, "SO_RCVTIMEO")) {
            const timeout = std.posix.timeval{
                .tv_sec = @intCast(milliseconds / 1000),
                .tv_usec = @intCast((milliseconds % 1000) * 1000),
            };
            try std.posix.setsockopt(
                self.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            );
        }
    }

    pub fn handshake(self: *PeerConnection) !void {
        std.debug.print("Starting handshake with peer...\n", .{});
        var handshake_buffer: [68]u8 = undefined;
        handshake_buffer[0] = 19;
        @memcpy(handshake_buffer[1..20], "BitTorrent protocol");
        @memset(handshake_buffer[20..28], 0);
        @memcpy(handshake_buffer[28..48], &self.info_hash);
        @memcpy(handshake_buffer[48..68], &self.peer_id);

        // Set a reasonable timeout for handshake
        try self.setReadTimeout(10 * 1000); // 10 second timeout

        try self.socket.writeAll(&handshake_buffer);

        var response: [68]u8 = undefined;
        const bytes_read = try self.socket.readAll(&response);

        if (bytes_read != 68) {
            std.debug.print("Invalid handshake response length: expected 68, got {}\n", .{bytes_read});
            return error.HandshakeFailed;
        }

        if (!std.mem.eql(u8, response[1..20], "BitTorrent protocol")) {
            std.debug.print("Invalid protocol identifier in handshake\n", .{});
            return error.HandshakeFailed;
        }
        if (!std.mem.eql(u8, response[28..48], &self.info_hash)) {
            std.debug.print("Info hash mismatch in handshake\n", .{});
            return error.HandshakeFailed;
        }
        std.debug.print("Handshake completed successfully\n", .{});
    }

    pub fn readMessage(self: *PeerConnection) !PeerMessage {
        var length_buf: [4]u8 = undefined;
        const bytes_read = try self.socket.read(&length_buf);
        if (bytes_read != 4) return error.ConnectionClosed;

        const length = std.mem.readInt(u32, &length_buf, .big);
        if (length == 0) return .keep_alive;

        var message_buf = try self.allocator.alloc(u8, length);
        defer self.allocator.free(message_buf);

        // Ensure we read exactly 'length' bytes
        var total_read: usize = 0;
        while (total_read < length) {
            const read_this_time = try self.socket.read(message_buf[total_read..]);
            if (read_this_time == 0) return error.ConnectionClosed;
            total_read += read_this_time;
        }

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

    fn sendMessageType(self: *PeerConnection, message_type: MessageType) !void {
        var buf: [5]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 1, .big);
        buf[4] = @intFromEnum(message_type);
        try self.socket.writeAll(&buf);
    }

    fn sendMessageBuffer(self: *PeerConnection, buffer: []const u8) !void {
        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, @intCast(buffer.len), .big);
        try self.socket.writeAll(&length_buf);
        try self.socket.writeAll(buffer);
    }
};
