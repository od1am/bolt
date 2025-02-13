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

    // Parse command-line arguments
    var conf = try cli.parseArgs(allocator);
    defer conf.deinit(allocator);

    // Load torrent file
    const data = try std.fs.cwd().readFileAlloc(allocator, conf.torrent_path, std.math.maxInt(usize));
    defer allocator.free(data);
    var torrent_file = try torrent.parseTorrentFile(allocator, data);
    defer torrent_file.deinit(allocator);

    // Initialize file I/O
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

    // Compute the output file path for the PieceManager.
    // This example creates a single output file by joining the output directory and the torrent name.
    const output_file_path = try std.fs.path.join(allocator, &[_][]const u8{ conf.output_dir, torrent_file.info.name });
    defer allocator.free(output_file_path);

    // Initialize piece manager using the output file path (not &file_io)
    var piece_manager = try PieceManager.init(
        allocator,
        torrent_file.info.piece_length,
        torrent_file.info.pieces.len / 20,
        try parsePieceHashes(allocator, torrent_file.info.pieces),
        output_file_path,
    );
    defer piece_manager.deinit();

    // Initialize networking
    const info_hash = try torrent_file.calculateInfoHash();
    var peer_manager = network.PeerManager.init(
        allocator,
        torrent_file,
        &piece_manager,
        &file_io,
        conf.peer_id,
        info_hash,
        // conf.max_peers,
    );
    defer peer_manager.deinit();

    // Get peers from tracker
    std.debug.print("Requesting peers from tracker...\n", .{});
    const tracker_response = try tracker.requestPeers(allocator, &torrent_file, // This is now correct as TorrentFile
        &conf.peer_id, conf.listen_port);
    defer allocator.free(tracker_response.peers);

    std.debug.print("Received {} bytes of peer data from tracker\n", .{tracker_response.peers.len});

    // Parse and connect to peers
    const peers = try network.parseCompactPeers(allocator, tracker_response.peers);
    defer allocator.free(peers);

    std.debug.print("Found {} peers\n", .{peers.items.len});

    for (peers.items) |peer_addr| {
        std.debug.print("Connecting to peer {}\n", .{peer_addr});
        peer_manager.connectToPeer(peer_addr) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
            continue;
        };
    }

    // Start download
    try peer_manager.startDownload();

    // Wait for completion
    while (!piece_manager.isDownloadComplete()) {
        std.time.sleep(1_000_000_000); // 1 second
    }
}

// Helper to split concatenated piece hashes into individual SHA-1 hashes
fn parsePieceHashes(allocator: Allocator, pieces: []const u8) ![]const [20]u8 {
    const num_pieces = pieces.len / 20;
    var hashes = try allocator.alloc([20]u8, num_pieces);
    for (0..num_pieces) |i| {
        const start = i * 20;
        @memcpy(&hashes[i], pieces[start .. start + 20]);
    }
    return hashes;
}
