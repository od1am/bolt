const std = @import("std");
const Allocator = std.mem.Allocator;
const torrent = @import("torrent.zig");
const bencode = @import("bencode.zig");
const StringArrayHashMap = std.StringArrayHashMap;
const net = std.net;
const posix = std.posix;

pub const Event = enum {
    none,
    started,
    stopped,
    completed,
};

pub const RequestParams = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,
    ip: ?[]const u8 = null,
    port: u16,
    amount_uploaded: u64,
    amount_downloaded: u64,
    left: u64,
    compact: bool = true,
    no_peer_id: bool = false,
    event: Event = .none,
    numwant: ?u32 = null,
    key: ?[]const u8 = null,
    trackerid: ?[]const u8 = null,
};

pub const Response = struct {
    interval: u32,
    min_interval: ?u32 = null,
    tracker_id: ?[]const u8 = null,
    complete: ?u32 = null,
    incomplete: ?u32 = null,
    peers: []const u8,
    peers6: ?[]const u8 = null,
    warning_message: ?[]const u8 = null,
};

pub fn requestPeers(allocator: Allocator, torrent_file: *const torrent.TorrentFile, params: RequestParams) !Response {
    const tracker_url = try buildTrackerUrl(allocator, torrent_file, params);
    defer allocator.free(tracker_url);

    const uri = try std.Uri.parse(tracker_url);

    if (std.mem.eql(u8, uri.scheme, "udp")) {
        std.debug.print("Using UDP tracker protocol\n", .{});
        return try sendUdpRequest(allocator, uri, params);
    } else if (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")) {
        std.debug.print("Using HTTP tracker protocol\n", .{});
        return try sendHttpRequest(allocator, tracker_url);
    } else if (std.mem.eql(u8, uri.scheme, "wss") or std.mem.eql(u8, uri.scheme, "ws")) {
        std.debug.print("WebSocket tracker protocol not supported yet: {s}\n", .{uri.scheme});
        return error.UnsupportedTrackerProtocol;
    } else {
        std.debug.print("Unsupported tracker protocol: {s}\n", .{uri.scheme});
        return error.UnsupportedTrackerProtocol;
    }
}

// New function for using a direct URL instead of torrent file's announce URL
pub fn requestPeersWithUrl(allocator: Allocator, tracker_url: []const u8, params: RequestParams, info_raw: []const u8) !Response {
    _ = info_raw; // Not used directly, but might be useful for future extensions

    const uri = try std.Uri.parse(tracker_url);

    if (std.mem.eql(u8, uri.scheme, "udp")) {
        std.debug.print("Using UDP tracker protocol with URL: {s}\n", .{tracker_url});
        return try sendUdpRequest(allocator, uri, params);
    } else if (std.mem.eql(u8, uri.scheme, "http") or std.mem.eql(u8, uri.scheme, "https")) {
        std.debug.print("Using HTTP tracker protocol with URL: {s}\n", .{tracker_url});

        // For HTTP, we need to build a full URL with query parameters
        const full_url = try buildTrackerUrlWithAnnounce(allocator, tracker_url, params);
        defer allocator.free(full_url);

        return try sendHttpRequest(allocator, full_url);
    } else if (std.mem.eql(u8, uri.scheme, "wss") or std.mem.eql(u8, uri.scheme, "ws")) {
        std.debug.print("WebSocket tracker protocol not supported yet: {s}\n", .{uri.scheme});
        return error.UnsupportedTrackerProtocol;
    } else {
        std.debug.print("Unsupported tracker protocol: {s}\n", .{uri.scheme});
        return error.UnsupportedTrackerProtocol;
    }
}

fn sendHttpRequest(allocator: Allocator, url: []const u8) !Response {
    const uri = try std.Uri.parse(url);

    if (uri.host == null) return error.InvalidUrl;

    var port: u16 = 80;
    if (uri.port) |p| {
        port = p;
    } else if (std.mem.eql(u8, uri.scheme, "https")) {
        port = 443;
    }

    const host_str = if (uri.host) |h| switch (h) {
        .raw => |t| t,
        .percent_encoded => |t| t,
    } else return error.InvalidUrl;

    std.debug.print("Connecting to tracker: {s}://{s}:{}\n", .{ uri.scheme, host_str, port });

    var socket: std.net.Stream = blk: {
        var attempts: u8 = 0;
        const max_attempts = 3;
        while (attempts < max_attempts) : (attempts += 1) {
            if (attempts > 0) {
                std.time.sleep(std.time.ns_per_s);
            }
            if (std.net.tcpConnectToHost(allocator, host_str, port)) |sock| {
                break :blk sock;
            } else |err| {
                std.debug.print("Connection attempt {d} failed: {}\n", .{ attempts + 1, err });
                if (attempts == max_attempts - 1) return err;
                continue;
            }
        }
        unreachable;
    };
    defer socket.close();

    const path = if (uri.path.percent_encoded.len > 0) uri.path.percent_encoded else "/";
    const query = if (uri.query) |q| q.percent_encoded else "";

    var full_path: []const u8 = undefined;
    var path_to_free: ?[]const u8 = null;

    if (query.len > 0) {
        full_path = try std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query });
        path_to_free = full_path;
    } else {
        full_path = path;
    }

    defer if (path_to_free != null) allocator.free(path_to_free.?);

    const request = try std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "User-Agent: Bolt/0.1.0\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ full_path, host_str });
    defer allocator.free(request);

    _ = try socket.writeAll(request);

    var buffer = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(buffer);

    var total_read: usize = 0;
    var content_start: ?usize = null;
    var content_length: ?usize = null;

    while (true) {
        const bytes_read = try socket.read(buffer[total_read..]);
        if (bytes_read == 0) break;

        total_read += bytes_read;

        if (content_start == null) {
            if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n")) |header_end| {
                content_start = header_end + 4;

                const headers = buffer[0..header_end];
                if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_pos| {
                    var end_pos = std.mem.indexOf(u8, headers[cl_pos..], "\r\n") orelse headers.len;
                    end_pos += cl_pos;
                    const cl_str = headers[cl_pos + 15 .. end_pos];
                    content_length = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " \t"), 10) catch null;
                }
            }
        }

        if (total_read >= buffer.len - 1024) {
            buffer = try allocator.realloc(buffer, buffer.len * 2);
        }

        if (content_start != null and content_length != null) {
            if (total_read >= content_start.? + content_length.?) {
                break;
            }
        }
    }

    const status_line_end = std.mem.indexOf(u8, buffer[0..total_read], "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = buffer[0..status_line_end];

    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and
        !std.mem.startsWith(u8, status_line, "HTTP/1.0 200"))
    {
        std.debug.print("HTTP request failed: {s}\n", .{status_line});
        return error.TrackerRequestFailed;
    }

    if (content_start == null) return error.InvalidHttpResponse;

    const body = buffer[content_start.?..total_read];
    std.debug.print("Received {} bytes from tracker\n", .{body.len});

    const body_copy = try allocator.dupe(u8, body);

    return try parseTrackerResponse(allocator, body_copy);
}

fn parseTrackerResponse(allocator: Allocator, response: []const u8) !Response {
    std.debug.print("Parsing tracker response...\n", .{});
    var decoded = try bencode.parse(allocator, response);
    defer decoded.deinit(allocator);

    if (decoded != .dict) {
        std.debug.print("Invalid tracker response: expected dictionary\n", .{});
        return error.InvalidTrackerResponse;
    }
    const dict = decoded.dict;

    if (dict.get("failure reason")) |failure| {
        if (failure == .string) {
            std.debug.print("Tracker failure: {s}\n", .{failure.string});
        }
        return error.TrackerFailure;
    }

    const interval_value = dict.get("interval") orelse {
        std.debug.print("Missing interval in tracker response\n", .{});
        return error.MissingInterval;
    };
    const interval = if (interval_value == .integer)
        @as(u32, @intCast(interval_value.integer))
    else {
        std.debug.print("Invalid interval value in tracker response\n", .{});
        return error.InvalidInterval;
    };

    std.debug.print("Tracker interval: {} seconds\n", .{interval});

    const min_interval = if (dict.get("min interval")) |mi|
        if (mi == .integer) @as(u32, @intCast(mi.integer)) else null
    else
        null;

    if (min_interval) |mi| {
        std.debug.print("Tracker min interval: {} seconds\n", .{mi});
    }

    const tracker_id = if (dict.get("tracker id")) |ti|
        if (ti == .string) try allocator.dupe(u8, ti.string) else null
    else
        null;

    const complete = if (dict.get("complete")) |c|
        if (c == .integer) @as(u32, @intCast(c.integer)) else null
    else
        null;

    const incomplete = if (dict.get("incomplete")) |i|
        if (i == .integer) @as(u32, @intCast(i.integer)) else null
    else
        null;

    if (complete) |c| std.debug.print("Complete peers: {}\n", .{c});
    if (incomplete) |i| std.debug.print("Incomplete peers: {}\n", .{i});

    const warning_message = if (dict.get("warning message")) |wm|
        if (wm == .string) try allocator.dupe(u8, wm.string) else null
    else
        null;

    if (warning_message) |wm| std.debug.print("Tracker warning: {s}\n", .{wm});

    const peers_value = dict.get("peers") orelse {
        std.debug.print("Missing peers in tracker response\n", .{});
        return error.MissingPeers;
    };
    const peers = if (peers_value == .string)
        try allocator.dupe(u8, peers_value.string)
    else {
        std.debug.print("Invalid peers value in tracker response\n", .{});
        return error.InvalidPeers;
    };
    errdefer allocator.free(peers);

    std.debug.print("Received {} bytes of peer data\n", .{peers.len});

    const peers6 = if (dict.get("peers6")) |p6|
        if (p6 == .string) try allocator.dupe(u8, p6.string) else null
    else
        null;

    if (peers6) |p6| std.debug.print("Received {} bytes of IPv6 peer data\n", .{p6.len});

    return Response{
        .interval = interval,
        .min_interval = min_interval,
        .tracker_id = tracker_id,
        .complete = complete,
        .incomplete = incomplete,
        .peers = peers,
        .peers6 = peers6,
        .warning_message = warning_message,
    };
}

fn buildTrackerUrl(allocator: Allocator, torrent_file: *const torrent.TorrentFile, params: RequestParams) ![]const u8 {
    if (torrent_file.announce_url) |url| {
        return buildTrackerUrlWithAnnounce(allocator, url, params);
    } else {
        return error.NoAnnounceUrl;
    }
}

fn buildTrackerUrlWithAnnounce(allocator: Allocator, announce: []const u8, params: RequestParams) ![]const u8 {
    var encoded_info_hash = try allocator.alloc(u8, params.info_hash.len * 3);
    defer allocator.free(encoded_info_hash);
    var encoded_peer_id = try allocator.alloc(u8, params.peer_id.len * 3);
    defer allocator.free(encoded_peer_id);

    var info_hash_len: usize = 0;
    var peer_id_len: usize = 0;

    for (params.info_hash) |byte| {
        if (isUrlSafe(byte)) {
            encoded_info_hash[info_hash_len] = byte;
            info_hash_len += 1;
        } else {
            const hex = try std.fmt.bufPrint(encoded_info_hash[info_hash_len..], "%{X:0>2}", .{byte});
            info_hash_len += hex.len;
        }
    }

    for (params.peer_id) |byte| {
        if (isUrlSafe(byte)) {
            encoded_peer_id[peer_id_len] = byte;
            peer_id_len += 1;
        } else {
            const hex = try std.fmt.bufPrint(encoded_peer_id[peer_id_len..], "%{X:0>2}", .{byte});
            peer_id_len += hex.len;
        }
    }

    const has_query = std.mem.indexOf(u8, announce, "?") != null;
    const separator = if (has_query) "&" else "?";

    var query_parts = std.ArrayList([]const u8).init(allocator);
    defer query_parts.deinit();

    try query_parts.append(try std.fmt.allocPrint(allocator, "info_hash={s}", .{encoded_info_hash[0..info_hash_len]}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "peer_id={s}", .{encoded_peer_id[0..peer_id_len]}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "port={d}", .{params.port}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "uploaded={d}", .{params.amount_uploaded}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "downloaded={d}", .{params.amount_downloaded}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "left={d}", .{params.left}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "compact={d}", .{@as(u8, if (params.compact) 1 else 0)}));

    if (params.no_peer_id) {
        try query_parts.append("no_peer_id=1");
    }

    if (params.event != .none) {
        const event_str = switch (params.event) {
            .started => "started",
            .stopped => "stopped",
            .completed => "completed",
            .none => unreachable,
        };
        try query_parts.append(try std.fmt.allocPrint(allocator, "event={s}", .{event_str}));
    }

    if (params.ip) |ip| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "ip={s}", .{ip}));
    }

    if (params.numwant) |numwant| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "numwant={d}", .{numwant}));
    }

    if (params.key) |key| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "key={s}", .{key}));
    }

    if (params.trackerid) |trackerid| {
        try query_parts.append(try std.fmt.allocPrint(allocator, "trackerid={s}", .{trackerid}));
    }

    const query = try std.mem.join(allocator, "&", query_parts.items);
    defer allocator.free(query);

    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ announce, separator, query });
}

fn isUrlSafe(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        byte == '.' or byte == '-' or byte == '_' or byte == '~';
}

pub fn parseCompactPeers(allocator: Allocator, data: []const u8) ![]net.Address {
    var peers = std.ArrayList(net.Address).init(allocator);
    errdefer peers.deinit();

    var i: usize = 0;
    while (i + 6 <= data.len) : (i += 6) {
        const ip_bytes = data[i..][0..4];
        const port_bytes = data[i + 4 ..][0..2];
        const port = std.mem.readInt(u16, port_bytes, .big);

        const ip4 = std.net.Ip4Address.init(ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], port);
        const addr = net.Address{ .in = ip4 };
        try peers.append(addr);
    }

    return peers.toOwnedSlice();
}

pub fn parseNonCompactPeers(allocator: Allocator, data: []const u8) ![]struct { peer_id: [20]u8, addr: net.Address } {
    var peers = std.ArrayList(struct { peer_id: [20]u8, addr: net.Address }).init(allocator);
    errdefer peers.deinit();

    var i: usize = 0;
    while (i < data.len) {
        const peer_id = data[i..][0..20];
        i += 20;

        const ip_bytes = data[i..][0..4];
        i += 4;

        const port_bytes = data[i..][0..2];
        const port = std.mem.readInt(u16, port_bytes, .big);
        i += 2;

        const ip4 = std.net.Ip4Address.init(ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], port);
        const addr = net.Address{ .in = ip4 };

        var peer_id_copy: [20]u8 = undefined;
        @memcpy(&peer_id_copy, peer_id);
        try peers.append(.{ .peer_id = peer_id_copy, .addr = addr });
    }

    return peers.toOwnedSlice();
}

fn sendUdpRequest(allocator: Allocator, uri: std.Uri, params: RequestParams) !Response {
    if (uri.host == null) return error.InvalidUrl;
    const host_str = if (uri.host) |h| switch (h) {
        .raw => |t| t,
        .percent_encoded => |t| t,
    } else return error.InvalidUrl;

    // Default port for UDP trackers is 80, but can be overridden
    var port: u16 = 80;
    if (uri.port) |p| {
        port = p;
    }

    std.debug.print("Connecting to UDP tracker: {s}:{}\n", .{ host_str, port });

    // Resolve hostname to IP address with better error handling
    const addr_list = net.getAddressList(allocator, host_str, port) catch |err| {
        std.debug.print("Failed to resolve UDP tracker hostname '{s}': {}\n", .{ host_str, err });
        return error.HostLookupFailed;
    };
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0) {
        std.debug.print("No addresses found for UDP tracker '{s}'\n", .{host_str});
        return error.HostLookupFailed;
    }

    const address = addr_list.addrs[0];
    std.debug.print("Resolved UDP tracker to {}\n", .{address});

    // Create UDP socket
    const socket = try posix.socket(address.any.family, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(socket);

    // Set socket timeout - start with a shorter timeout for first attempt
    const timeout = posix.timeval{
        .sec = 5, // 5 seconds initial timeout (reduced from 15)
        .usec = 0,
    };
    posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch |err| {
        std.debug.print("Warning: Failed to set socket timeout: {}\n", .{err});
    };

    // Also set send timeout
    posix.setsockopt(
        socket,
        posix.SOL.SOCKET,
        posix.SO.SNDTIMEO,
        std.mem.asBytes(&timeout),
    ) catch |err| {
        std.debug.print("Warning: Failed to set socket send timeout: {}\n", .{err});
    };

    // Step 1: Connect Packet
    const connection_id = sendUdpConnectRequest(socket, address) catch |err| {
        std.debug.print("Failed to connect to UDP tracker: {}\n", .{err});
        return error.UdpConnectFailed;
    };

    // Step 2: Announce Packet with our parameters
    return sendUdpAnnounceRequest(allocator, socket, address, connection_id, params) catch |err| {
        std.debug.print("Failed to announce to UDP tracker: {}\n", .{err});
        return error.UdpAnnounceFailed;
    };
}

// UDP protocol constants
const UDP_CONNECT_ACTION: u32 = 0;
const UDP_ANNOUNCE_ACTION: u32 = 1;
const UDP_SCRAPE_ACTION: u32 = 2;
const UDP_ERROR_ACTION: u32 = 3;
const UDP_MAGIC: u64 = 0x41727101980;

fn sendUdpConnectRequest(socket: posix.socket_t, address: net.Address) !u64 {
    var connect_req = std.mem.zeroes([16]u8);

    // Fill connection request: magic + action
    std.mem.writeInt(u64, connect_req[0..8], UDP_MAGIC, .big);
    std.mem.writeInt(u32, connect_req[8..12], UDP_CONNECT_ACTION, .big);

    // Generate transaction ID (random number)
    const transaction_id = @as(u32, @intCast(@mod(std.time.milliTimestamp(), 0x100000000)));
    std.mem.writeInt(u32, connect_req[12..16], transaction_id, .big);

    // Maximum number of retries
    var retries: u8 = 0;
    const max_retries = 3; // Reduced from 8 to try other trackers more quickly
    var timeout_seconds: u64 = 5; // Start with 5s timeout (reduced from 15)

    while (retries < max_retries) : (retries += 1) {
        // Send connect request
        const sent = try posix.sendto(
            socket,
            &connect_req,
            0,
            &address.any,
            address.getOsSockLen(),
        );

        if (sent != connect_req.len) {
            std.debug.print("UDP connect request: sent {} bytes, expected {}\n", .{ sent, connect_req.len });
            if (retries == max_retries - 1) return error.SendError;
            continue;
        }

        // Receive response
        var response_buf: [16]u8 = undefined;
        var src_addr: posix.sockaddr = undefined;
        var src_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        // Add a safety check to ensure we don't overflow the buffer
        const max_recv_size = response_buf.len;

        const received = posix.recvfrom(
            socket,
            &response_buf,
            0,
            &src_addr,
            &src_addr_len,
        ) catch |err| {
            if (err == error.WouldBlock or err == error.ConnectionTimedOut) {
                std.debug.print("UDP connect timed out, retry {} with timeout {}s\n", .{ retries + 1, timeout_seconds });
                // More gradual backoff
                timeout_seconds = if (timeout_seconds < 10) 10 else timeout_seconds + 5;

                // Update socket timeout
                const new_timeout = posix.timeval{
                    .sec = @intCast(timeout_seconds),
                    .usec = 0,
                };

                posix.setsockopt(
                    socket,
                    posix.SOL.SOCKET,
                    posix.SO.RCVTIMEO,
                    std.mem.asBytes(&new_timeout),
                ) catch |timeout_err| {
                    std.debug.print("Warning: Failed to update socket timeout: {}\n", .{timeout_err});
                };

                continue;
            }
            return err;
        };

        if (received < 16 or received > max_recv_size) {
            std.debug.print("UDP connect response invalid: got {} bytes (expected 16, max {})\n", .{ received, max_recv_size });
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        // Validate transaction ID
        const resp_action = std.mem.readInt(u32, response_buf[0..4], .big);
        const resp_transaction = std.mem.readInt(u32, response_buf[4..8], .big);

        if (resp_transaction != transaction_id) {
            std.debug.print("UDP transaction ID mismatch\n", .{});
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        if (resp_action == UDP_ERROR_ACTION) {
            std.debug.print("UDP tracker returned error\n", .{});
            return error.TrackerError;
        }

        if (resp_action != UDP_CONNECT_ACTION) {
            std.debug.print("UDP action mismatch, expected {}, got {}\n", .{ UDP_CONNECT_ACTION, resp_action });
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        // Extract connection ID
        const connection_id = std.mem.readInt(u64, response_buf[8..16], .big);
        return connection_id;
    }

    return error.MaxRetriesExceeded;
}

fn sendUdpAnnounceRequest(
    allocator: Allocator,
    socket: posix.socket_t,
    address: net.Address,
    connection_id: u64,
    params: RequestParams,
) !Response {
    // Create announce request (98 bytes)
    var announce_req = std.mem.zeroes([98]u8);

    // Connection ID (8 bytes)
    std.mem.writeInt(u64, announce_req[0..8], connection_id, .big);

    // Action - announce (4 bytes)
    std.mem.writeInt(u32, announce_req[8..12], UDP_ANNOUNCE_ACTION, .big);

    // Transaction ID (4 bytes)
    const transaction_id = @as(u32, @intCast(@mod(std.time.milliTimestamp(), 0x100000000)));
    std.mem.writeInt(u32, announce_req[12..16], transaction_id, .big);

    // Info hash (20 bytes)
    @memcpy(announce_req[16..36], &params.info_hash);

    // Peer ID (20 bytes)
    @memcpy(announce_req[36..56], &params.peer_id);

    // Downloaded (8 bytes)
    std.mem.writeInt(u64, announce_req[56..64], params.amount_downloaded, .big);

    // Left (8 bytes)
    std.mem.writeInt(u64, announce_req[64..72], params.left, .big);

    // Uploaded (8 bytes)
    std.mem.writeInt(u64, announce_req[72..80], params.amount_uploaded, .big);

    // Event (4 bytes)
    const event: u32 = switch (params.event) {
        .none => 0,
        .completed => 1,
        .started => 2,
        .stopped => 3,
    };
    std.mem.writeInt(u32, announce_req[80..84], event, .big);

    // IP address (4 bytes) - 0 = use sender's address
    std.mem.writeInt(u32, announce_req[84..88], 0, .big);

    // Key (4 bytes) - random number
    std.mem.writeInt(u32, announce_req[88..92], transaction_id ^ 0xFF, .big);

    // Num Want (-1 = default)
    const num_want: i32 = if (params.numwant) |n| @intCast(n) else -1;
    std.mem.writeInt(i32, announce_req[92..96], num_want, .big);

    // Port
    std.mem.writeInt(u16, announce_req[96..98], params.port, .big);

    // Maximum number of retries
    var retries: u8 = 0;
    const max_retries = 3; // Reduced from 8 to try other trackers more quickly
    var timeout_seconds: u64 = 5; // Start with 5s timeout (reduced from 15)

    while (retries < max_retries) : (retries += 1) {
        // Send announce request
        const sent = try posix.sendto(
            socket,
            &announce_req,
            0,
            &address.any,
            address.getOsSockLen(),
        );

        if (sent != announce_req.len) {
            std.debug.print("UDP announce request: sent {} bytes, expected {}\n", .{ sent, announce_req.len });
            if (retries == max_retries - 1) return error.SendError;
            continue;
        }

        // Receive response - allocate enough space for a response with many peers
        // Use a fixed-size buffer on the stack for safety
        var response_buf: [16 * 1024]u8 = undefined;
        var received_data: []u8 = undefined;

        var src_addr: posix.sockaddr = undefined;
        var src_addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);

        const received = posix.recvfrom(
            socket,
            &response_buf,
            0,
            &src_addr,
            &src_addr_len,
        ) catch |err| {
            if (err == error.WouldBlock or err == error.ConnectionTimedOut) {
                std.debug.print("UDP announce timed out, retry {} with timeout {}s\n", .{ retries + 1, timeout_seconds });
                // More gradual backoff
                timeout_seconds = if (timeout_seconds < 10) 10 else timeout_seconds + 5;

                // Update socket timeout
                const new_timeout = posix.timeval{
                    .sec = @intCast(timeout_seconds),
                    .usec = 0,
                };

                posix.setsockopt(
                    socket,
                    posix.SOL.SOCKET,
                    posix.SO.RCVTIMEO,
                    std.mem.asBytes(&new_timeout),
                ) catch |timeout_err| {
                    std.debug.print("Warning: Failed to update socket timeout: {}\n", .{timeout_err});
                };

                continue;
            }
            return err;
        };

        if (received < 20) { // Minimum response size
            std.debug.print("UDP announce response too short: got {} bytes\n", .{received});
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        // Store the valid received data for processing
        received_data = response_buf[0..received];

        // Validate response
        const resp_action = std.mem.readInt(u32, received_data[0..4], .big);
        const resp_transaction = std.mem.readInt(u32, received_data[4..8], .big);

        if (resp_transaction != transaction_id) {
            std.debug.print("UDP announce transaction ID mismatch\n", .{});
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        if (resp_action == UDP_ERROR_ACTION) {
            // Error message might be included in the response
            if (received > 8) {
                // Instead of using sliceTo, just print the raw error message bytes
                const max_msg_len = @min(received - 8, 100); // Limit to 100 chars
                std.debug.print("UDP tracker returned error: {s}\n", .{received_data[8 .. 8 + max_msg_len]});
            } else {
                std.debug.print("UDP tracker returned error with no message\n", .{});
            }
            return error.TrackerError;
        }

        if (resp_action != UDP_ANNOUNCE_ACTION) {
            std.debug.print("UDP action mismatch, expected {}, got {}\n", .{ UDP_ANNOUNCE_ACTION, resp_action });
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        // Parse response
        const interval = std.mem.readInt(u32, received_data[8..12], .big);
        const leechers = std.mem.readInt(u32, received_data[12..16], .big);
        const seeders = std.mem.readInt(u32, received_data[16..20], .big);

        std.debug.print("UDP tracker response: interval={}, leechers={}, seeders={}\n", .{ interval, leechers, seeders });

        // Peers data starts at byte 20
        // Make sure we have enough data for at least one peer (6 bytes per peer)
        if (received < 26) { // 20 bytes header + at least 6 bytes for one peer
            std.debug.print("UDP tracker response doesn't contain enough peer data\n", .{});
            if (retries == max_retries - 1) return error.InvalidResponse;
            continue;
        }

        const peers_data = received_data[20..received];
        std.debug.print("Received {} bytes of peer data from UDP tracker\n", .{peers_data.len});

        // Validate that the peer data length is a multiple of 6 (IPv4 address + port)
        if (peers_data.len % 6 != 0) {
            std.debug.print("Warning: UDP tracker returned peer data with length not divisible by 6\n", .{});
            // We'll continue anyway and just use the valid peers
        }

        // Create response with a safe copy of the peer data
        return Response{
            .interval = interval,
            .min_interval = null,
            .tracker_id = null,
            .complete = seeders,
            .incomplete = leechers,
            .peers = try allocator.dupe(u8, peers_data),
            .peers6 = null,
            .warning_message = null,
        };
    }

    return error.MaxRetriesExceeded;
}
