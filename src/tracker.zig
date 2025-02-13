const std = @import("std");
const Allocator = std.mem.Allocator;
const BencodeValue = @import("bencode.zig").BencodeValue;
const TorrentFile = @import("torrent.zig").TorrentFile;
const StringArrayHashMap = std.StringArrayHashMap;

// Struct to represent the tracker response
pub const TrackerResponse = struct {
    interval: usize, // How often to re-announce (in seconds)
    peers: []const u8, // List of peers (compact format: 6 bytes per peer)
};

// Struct to represent a peer
pub const Peer = struct {
    ip: []const u8, // IP address of the peer
    port: u16, // Port number of the peer
};

// Contact the tracker and fetch the list of peers
pub fn requestPeers(allocator: Allocator, torrent_file: *const TorrentFile, peer_id: *const [20]u8, port: u16) !TrackerResponse {
    std.debug.print("Building tracker URL...\n", .{});
    const tracker_url = try buildTrackerUrl(allocator, torrent_file, peer_id, port);
    defer allocator.free(tracker_url);

    std.debug.print("Sending request to tracker: {s}\n", .{tracker_url});
    const response = try sendHttpRequest(allocator, tracker_url);
    defer allocator.free(response);

    std.debug.print("Received {} bytes from tracker\n", .{response.len});
    return parseTrackerResponse(allocator, response);
}

// Build the tracker URL with query parameters
fn buildTrackerUrl(allocator: Allocator, torrent_file: *const TorrentFile, peer_id: *const [20]u8, port: u16) ![]const u8 {
    const info_hash = try torrent_file.calculateInfoHash();
    defer allocator.free(info_hash);

    var url = std.ArrayList(u8).init(allocator);
    defer url.deinit();

    try url.writer().print("{s}?info_hash={s}&peer_id={s}&port={}&uploaded=0&downloaded=0&left={}&compact=1", .{
        torrent_file.announce,
        std.fmt.fmtSliceHexLower(&info_hash),
        peer_id,
        port,
        torrent_file.info.length orelse blk: {
            var total_length: usize = 0;
            if (torrent_file.info.files) |files| {
                for (files) |file| {
                    total_length += file.length;
                }
            }
            break :blk total_length;
        },
    });

    return url.toOwnedSlice();
}

// Send an HTTP GET request to the tracker
fn sendHttpRequest(allocator: Allocator, url: []const u8) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers = std.http.Header{ .headers = std.http.Headers.init(allocator) };
    defer headers.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.open(.GET, uri, headers, .{});
    defer req.deinit();

    try req.send(.{});
    try req.finish();

    const status = req.response.status;
    if (status != .ok) {
        return error.TrackerRequestFailed;
    }

    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit();

    try req.response.reader().readAllArrayList(&response, std.math.maxInt(usize));
    return response.toOwnedSlice();
}

// Parse the tracker response (Bencoded format)
fn parseTrackerResponse(allocator: Allocator, response: []const u8) !TrackerResponse {
    const bencode_value = try BencodeValue.parse(allocator, response);
    defer bencode_value.deinit(allocator);

    if (bencode_value != .dict) return error.InvalidTrackerResponse;

    const interval = try extractInteger(bencode_value.dict, "interval");
    const peers = try extractString(allocator, bencode_value.dict, "peers");

    return TrackerResponse{
        .interval = interval,
        .peers = peers,
    };
}

// Extract an integer from the Bencoded dictionary
fn extractInteger(dict: StringArrayHashMap(BencodeValue), key: []const u8) !usize {
    const value = dict.get(key) orelse return error.InvalidTrackerResponse;
    if (value != .integer) return error.InvalidTrackerResponse;
    return @intCast(value.integer);
}

// Extract a string from the Bencoded dictionary
fn extractString(allocator: Allocator, dict: StringArrayHashMap(BencodeValue), key: []const u8) ![]const u8 {
    const value = dict.get(key) orelse return error.InvalidTrackerResponse;
    if (value != .string) return error.InvalidTrackerResponse;
    return try allocator.dupe(u8, value.string);
}

// Parse the compact peer list into individual peers
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

        const port = std.mem.readIntBig(u16, port_bytes[0..2]);

        peer.ip = try ip.toOwnedSlice();
        peer.port = port;
    }

    return peer_list;
}