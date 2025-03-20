const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const config = @import("config.zig");
const torrent = @import("torrent.zig");
const network = @import("networking.zig");
const PieceManager = @import("piece_manager.zig").PieceManager;
const FileIO = @import("file_io.zig").FileIO;
const tracker = @import("tracker.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var conf = try cli.parseArgs(allocator);
    defer conf.deinit(allocator);

    const data = try std.fs.cwd().readFileAlloc(allocator, conf.torrent_path, std.math.maxInt(usize));
    defer allocator.free(data);
    var torrent_file = try torrent.parseTorrentFile(allocator, data);
    defer torrent_file.deinit(allocator);

    const single_file = if (torrent_file.info.files == null)
        [_]torrent.File{.{
            .path = torrent_file.info.name,
            .length = torrent_file.info.length orelse 0,
        }}
    else
        undefined;

    const files: []const torrent.File = if (torrent_file.info.files) |f| f else &single_file;
    var file_io = try FileIO.init(allocator, files, torrent_file.info.piece_length, conf.output_dir);
    defer file_io.deinit();

    const output_file_path = try std.fs.path.join(allocator, &[_][]const u8{ conf.output_dir, torrent_file.info.name });
    defer allocator.free(output_file_path);

    var piece_manager = try PieceManager.init(
        allocator,
        torrent_file.info.piece_length,
        torrent_file.info.pieces.len / 20,
        try parsePieceHashes(allocator, torrent_file.info.pieces),
        output_file_path,
    );
    defer piece_manager.deinit();

    const info_hash = try torrent_file.calculateInfoHash();
    var peer_manager = network.PeerManager.init(
        allocator,
        torrent_file,
        &piece_manager,
        &file_io,
        conf.peer_id,
        info_hash,
    );
    defer peer_manager.deinit();

    std.debug.print("Requesting peers from tracker...\n", .{});
    const total_size = if (torrent_file.info.length) |len| len else blk: {
        var sum: usize = 0;
        for (files) |file| {
            sum += file.length;
        }
        break :blk sum;
    };
    const params = tracker.RequestParams{
        .info_hash = info_hash,
        .peer_id = conf.peer_id,
        .port = conf.listen_port,
        .uploaded = 0,
        .downloaded = 0,
        .left = total_size,
        .compact = true,
    };
    const tracker_response = try tracker.requestPeers(allocator, &torrent_file, params);
    defer allocator.free(tracker_response.peers);

    std.debug.print("Received {} bytes of peer data from tracker\n", .{tracker_response.peers.len});

    const peers = try network.parseCompactPeers(allocator, tracker_response.peers);
    defer allocator.free(peers);

    std.debug.print("Found {} peers\n", .{peers.len});

    for (peers) |peer_addr| {
        std.debug.print("Connecting to peer {}\n", .{peer_addr});
        peer_manager.connectToPeer(peer_addr) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
            continue;
        };
    }

    try peer_manager.startDownload();

    while (!piece_manager.isDownloadComplete()) {
        std.time.sleep(1_000_000_000); // 1 second
    }
}

fn parsePieceHashes(allocator: Allocator, pieces: []const u8) ![]const [20]u8 {
    const num_pieces = pieces.len / 20;
    var hashes = try allocator.alloc([20]u8, num_pieces);
    for (0..num_pieces) |i| {
        const start = i * 20;
        @memcpy(&hashes[i], pieces[start .. start + 20]);
    }
    return hashes;
}

fn parseTorrentFile(allocator: Allocator, data: []const u8) !torrent.TorrentFile {
    return try torrent.parseTorrentFile(allocator, data);
}
