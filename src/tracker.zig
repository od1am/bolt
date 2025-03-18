const std = @import("std");
const Allocator = std.mem.Allocator;
const torrent = @import("torrent.zig");
const bencode = @import("bencode.zig");
const StringArrayHashMap = std.StringArrayHashMap;
const net = @import("std").net;

pub const Event = enum {
    none,
    started,
    stopped,
    completed,
};

pub const RequestParams = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    compact: bool = true,
    no_peer_id: bool = false,
    event: Event = .none,
    ip: ?[]const u8 = null,
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

    return try sendHttpRequest(allocator, tracker_url);
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
    var decoded = try bencode.parse(allocator, response);
    defer decoded.deinit(allocator);

    if (decoded != .dict) return error.InvalidTrackerResponse;
    const dict = decoded.dict;

    if (dict.get("failure reason")) |failure| {
        if (failure == .string) {
            std.debug.print("Tracker failure: {s}\n", .{failure.string});
        }
        return error.TrackerFailure;
    }

    const interval_value = dict.get("interval") orelse return error.MissingInterval;
    const interval = if (interval_value == .integer)
        @as(u32, @intCast(interval_value.integer))
    else
        return error.InvalidInterval;

    const min_interval = if (dict.get("min interval")) |mi| 
        if (mi == .integer) @as(u32, @intCast(mi.integer)) else null
    else null;

    const tracker_id = if (dict.get("tracker id")) |ti|
        if (ti == .string) try allocator.dupe(u8, ti.string) else null
    else null;

    const complete = if (dict.get("complete")) |c|
        if (c == .integer) @as(u32, @intCast(c.integer)) else null
    else null;

    const incomplete = if (dict.get("incomplete")) |i|
        if (i == .integer) @as(u32, @intCast(i.integer)) else null
    else null;

    const warning_message = if (dict.get("warning message")) |wm|
        if (wm == .string) try allocator.dupe(u8, wm.string) else null
    else null;

    const peers_value = dict.get("peers") orelse return error.MissingPeers;
    const peers = if (peers_value == .string)
        try allocator.dupe(u8, peers_value.string)
    else
        return error.InvalidPeers;
    errdefer allocator.free(peers);

    const peers6 = if (dict.get("peers6")) |p6|
        if (p6 == .string) try allocator.dupe(u8, p6.string) else null
    else null;

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
    return buildTrackerUrlWithAnnounce(allocator, torrent_file.announce_url, params);
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
    try query_parts.append(try std.fmt.allocPrint(allocator, "uploaded={d}", .{params.uploaded}));
    try query_parts.append(try std.fmt.allocPrint(allocator, "downloaded={d}", .{params.downloaded}));
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
