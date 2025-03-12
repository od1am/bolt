const std = @import("std");
const Allocator = std.mem.Allocator;
const torrent = @import("torrent.zig");
const bencode = @import("bencode.zig");
const StringArrayHashMap = std.StringArrayHashMap;

pub const Response = struct {
    interval: u32,
    peers: []const u8,
};

pub const Peer = struct {
    ip: []const u8,
    port: u16,
};

pub fn requestPeers(allocator: Allocator, torrent_file: *const torrent.TorrentFile, peer_id: *const [20]u8, port: u16) !Response {
    const tracker_url = try buildTrackerUrl(allocator, torrent_file, peer_id, port);
    defer allocator.free(tracker_url);
    
    std.debug.print("Tracker URL: {s}\n", .{tracker_url});
    
    const response = sendHttpRequest(allocator, tracker_url) catch |err| {
        std.debug.print("Tracker request failed: {}\n", .{err});
        // Try to use backup trackers if available
        if (torrent_file.announce_list != null and torrent_file.announce_list.?.len > 0) {
            std.debug.print("Trying backup trackers...\n", .{});
            for (torrent_file.announce_list.?) |announce| {
                const backup_url = try buildTrackerUrlWithAnnounce(allocator, announce, torrent_file, peer_id, port);
                defer allocator.free(backup_url);
                std.debug.print("Trying backup tracker: {s}\n", .{backup_url});
                if (sendHttpRequest(allocator, backup_url)) |resp| {
                    return resp;
                } else |backup_err| {
                    std.debug.print("Backup tracker failed: {}\n", .{backup_err});
                    continue;
                }
            }
        }
        return err;
    };
    
    return response;
}

fn sendHttpRequest(allocator: Allocator, url: []const u8) !Response {
    const uri = try std.Uri.parse(url);
    
    // Validate URI
    if (uri.host == null) return error.InvalidUrl;
    
    const port = if (uri.port) |p| p else blk: {
        if (std.mem.eql(u8, uri.scheme, "https")) {
            break :blk 443;
        } else {
            break :blk 80;
        }
    };
    
    std.debug.print("Connecting to tracker: {s}://{s}:{}\n", .{
        uri.scheme, uri.host.?, port
    });
    
    // Create socket
    const socket = try std.net.tcpConnectToHost(allocator, uri.host.?, port);
    defer socket.close();
    
    // Build HTTP request
    const path = if (uri.path.len > 0) uri.path else "/";
    const query = if (uri.query) |q| q else "";
    
    var full_path: []const u8 = undefined;
    var path_to_free: ?[]const u8 = null;
    
    if (query.len > 0) {
        full_path = try std.fmt.allocPrint(allocator, "{s}?{s}", .{path, query});
        path_to_free = full_path;
    } else {
        full_path = path;
    }
    defer if (path_to_free != null) allocator.free(path_to_free.?);
    
    const request = try std.fmt.allocPrint(allocator, 
        "GET {s} HTTP/1.1\r\n" ++
        "Host: {s}\r\n" ++
        "User-Agent: Bolt/0.1.0\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", 
        .{full_path, uri.host.?}
    );
    defer allocator.free(request);
    
    std.debug.print("Sending HTTP request:\n{s}\n", .{request});
    
    // Send request
    _ = try socket.writeAll(request); // Changed from write to writeAll
    
    // Read response
    var buffer = try allocator.alloc(u8, 16 * 1024); // 16KB buffer
    defer allocator.free(buffer);
    
    var total_read: usize = 0;
    var content_start: ?usize = null;
    var content_length: ?usize = null;
    
    while (true) {
        const bytes_read = try socket.read(buffer[total_read..]);
        if (bytes_read == 0) break;
        
        total_read += bytes_read;
        
        // Check if we've found the end of headers
        if (content_start == null) {
            if (std.mem.indexOf(u8, buffer[0..total_read], "\r\n\r\n")) |header_end| {
                content_start = header_end + 4;
                
                // Parse headers to find content length
                const headers = buffer[0..header_end];
                if (std.mem.indexOf(u8, headers, "Content-Length:")) |cl_pos| {
                    var end_pos = std.mem.indexOf(u8, headers[cl_pos..], "\r\n") orelse headers.len;
                    end_pos += cl_pos;
                    const cl_str = headers[cl_pos + 15..end_pos];
                    content_length = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " \t"), 10) catch null;
                }
            }
        }
        
        // Check if we need to resize the buffer
        if (total_read >= buffer.len - 1024) {
            buffer = try allocator.realloc(buffer, buffer.len * 2);
        }
        
        // Check if we've read the full content
        if (content_start != null and content_length != null) {
            if (total_read >= content_start.? + content_length.?) {
                break;
            }
        }
    }
    
    // Check for HTTP status code
    const status_line_end = std.mem.indexOf(u8, buffer[0..total_read], "\r\n") orelse return error.InvalidHttpResponse;
    const status_line = buffer[0..status_line_end];
    
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and 
        !std.mem.startsWith(u8, status_line, "HTTP/1.0 200")) {
        std.debug.print("HTTP request failed: {s}\n", .{status_line});
        return error.TrackerRequestFailed;
    }
    
    // Extract body
    if (content_start == null) return error.InvalidHttpResponse;
    
    const body = buffer[content_start.?..total_read];
    std.debug.print("Received {} bytes from tracker\n", .{body.len});
    
    // Copy the body to a new buffer
    const body_copy = try allocator.dupe(u8, body);
    
    return try parseTrackerResponse(allocator, body_copy);
}

fn parseTrackerResponse(allocator: Allocator, response: []const u8) !Response {
    var stream = std.io.fixedBufferStream(response);
    const decoded = try bencode.decode(allocator, stream.reader());
    defer decoded.deinit();
    
    if (decoded.data != .dictionary) return error.InvalidTrackerResponse;
    
    const dict = decoded.data.dictionary;
    
    // Check for failure
    if (dict.get("failure reason")) |failure| {
        if (failure.data == .string) {
            std.debug.print("Tracker failure: {s}\n", .{failure.data.string});
        }
        return error.TrackerFailure;
    }
    
    const interval_value = dict.get("interval") orelse return error.MissingInterval;
    const interval = if (interval_value.data == .integer) 
        @as(u32, @intCast(interval_value.data.integer)) 
    else 
        return error.InvalidInterval;
    
    const peers_value = dict.get("peers") orelse return error.MissingPeers;
    const peers = if (peers_value.data == .string) 
        try allocator.dupe(u8, peers_value.data.string) 
    else 
        return error.InvalidPeers;
    
    return Response{
        .interval = interval,
        .peers = peers,
    };
}

fn buildTrackerUrl(allocator: Allocator, torrent_file: *const torrent.TorrentFile, peer_id: *const [20]u8, port: u16) ![]const u8 {
    return buildTrackerUrlWithAnnounce(allocator, torrent_file.announce, torrent_file, peer_id, port);
}

fn buildTrackerUrlWithAnnounce(allocator: Allocator, announce: []const u8, torrent_file: *const torrent.TorrentFile, peer_id: *const [20]u8, port: u16) ![]const u8 {
    const info_hash = try torrent_file.calculateInfoHash();
    
    // URL encode the info_hash and peer_id
    var encoded_info_hash = try allocator.alloc(u8, info_hash.len * 3);
    defer allocator.free(encoded_info_hash);
    var encoded_peer_id = try allocator.alloc(u8, peer_id.len * 3);
    defer allocator.free(encoded_peer_id);
    
    var info_hash_len: usize = 0;
    var peer_id_len: usize = 0;
    
    for (info_hash) |byte| {
        const hex = try std.fmt.bufPrint(encoded_info_hash[info_hash_len..], "%%%02X", .{byte});
        info_hash_len += hex.len;
    }
    
    for (peer_id.*) |byte| {
        const hex = try std.fmt.bufPrint(encoded_peer_id[peer_id_len..], "%%%02X", .{byte});
        peer_id_len += hex.len;
    }
    
    // Calculate total file size for the "left" parameter
    var total_size: u64 = 0;
    if (torrent_file.info.files) |files| {
        for (files) |file| {
            total_size += file.length;
        }
    } else if (torrent_file.info.length) |length| {
        total_size = length;
    }
    
    // Check if the announce URL already has query parameters
    const has_query = std.mem.indexOf(u8, announce, "?") != null;
    const separator = if (has_query) "&" else "?";
    
    // Build the URL with all required parameters
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}info_hash={s}&peer_id={s}&port={d}&uploaded=0&downloaded=0&left={d}&compact=1&event=started",
        .{
            announce,
            separator,
            encoded_info_hash[0..info_hash_len],
            encoded_peer_id[0..peer_id_len],
            port,
            total_size,
        }
    );
}

pub fn parseCompactPeers(allocator: Allocator, peers: []const u8) ![]Peer {
    if (peers.len % 6 != 0) return error.InvalidPeerList;
    const num_peers = peers.len / 6;
    const peer_list = try allocator.alloc(Peer, num_peers);

    for (peer_list, 0..) |*peer, i| {
        const offset = i * 6;
        const ip_bytes = peers[offset .. offset + 4];
        const port_bytes = peers[offset + 4 .. offset + 6];

        var ip = std.ArrayList(u8).init(allocator);
        defer ip.deinit();
        try ip.writer().print("{}.{}.{}.{}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] });

        const port = std.mem.readInt(u16, port_bytes[0..2], .big);

        peer.ip = try ip.toOwnedSlice();
        peer.port = port;
    }

    return peer_list;
}
