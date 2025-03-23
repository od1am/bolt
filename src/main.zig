const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const config = @import("config.zig");
const torrent = @import("torrent.zig");
const network = @import("networking.zig");
const PieceManager = @import("piece_manager.zig").PieceManager;
const FileIO = @import("file_io.zig").FileIO;
const tracker = @import("tracker.zig");
const net = std.net;

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

    const tracker_response = tracker.requestPeers(allocator, &torrent_file, params) catch |err| {
        std.debug.print("Failed to connect to tracker: {}\n", .{err});
        std.debug.print("Continuing with any hardcoded or known peers instead...\n", .{});
        return err;
    };
    defer allocator.free(tracker_response.peers);

    std.debug.print("Received {} bytes of peer data from tracker\n", .{tracker_response.peers.len});

    const peers = try network.parseCompactPeers(allocator, tracker_response.peers);
    defer allocator.free(peers);

    std.debug.print("Found {} peers\n", .{peers.len});

    var successful_connections: usize = 0;
    const max_initial_connections = 5; // Only try to connect to 5 peers initially
    var started_download = false;

    // Connect to the first few peers
    for (0..@min(peers.len, max_initial_connections)) |i| {
        const peer_addr = peers[i];

        std.debug.print("Connecting to peer {}\n", .{peer_addr});
        peer_manager.connectToPeer(peer_addr) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
            continue;
        };
        successful_connections += 1;

        // Start downloading as soon as we connect to the first peer
        if (successful_connections == 1 and !started_download) {
            std.debug.print("Starting download with first peer\n", .{});
            try peer_manager.startDownload();
            started_download = true;
        }
    }

    if (successful_connections == 0) {
        std.debug.print("Failed to connect to any peers. Exiting.\n", .{});
        return error.NoPeersAvailable;
    }

    // If we didn't start the download yet (should be rare), start it now
    if (!started_download) {
        try peer_manager.startDownload();
    }

    // Start a thread to connect to remaining peers in the background
    if (peers.len > max_initial_connections) {
        const remaining_peers = peers[max_initial_connections..];
        var thread = try std.Thread.spawn(.{}, connectRemainingPeers, .{
            &peer_manager,
            remaining_peers,
        });
        thread.detach();
    }

    var last_progress: usize = 0;
    var last_report_time = std.time.milliTimestamp();
    const report_interval = 5000; // 5 seconds
    var stall_warning_displayed = false;
    var start_waiting_message_displayed = false;
    var download_started = false;

    std.debug.print("Waiting for download to begin...\n", .{});

    while (!piece_manager.isDownloadComplete()) {
        const current_time = std.time.milliTimestamp();
        const progress = piece_manager.downloaded_pieces;

        // Check if download has started
        if (progress > 0 and !download_started) {
            std.debug.print("DOWNLOAD CONFIRMED: First piece downloaded! Download has successfully started.\n", .{});
            download_started = true;
        }

        // Show initial waiting message
        if (progress == 0 and !start_waiting_message_displayed and current_time - last_report_time > report_interval) {
            std.debug.print("Waiting for peers to unchoke us and start sending data...\n", .{});
            last_report_time = current_time;
            start_waiting_message_displayed = true;
        }

        // Regular progress update
        if (current_time - last_report_time > report_interval and (progress > 0 or progress != last_progress)) {
            const percent = @as(f32, @floatFromInt(progress)) / @as(f32, @floatFromInt(piece_manager.total_pieces)) * 100.0;
            std.debug.print("Download progress: {d:.1}% ({}/{} pieces)\n", .{ percent, progress, piece_manager.total_pieces });
            last_report_time = current_time;
            last_progress = progress;
            stall_warning_displayed = false;
        }

        // Check for download stall
        if (current_time - last_report_time > 30000 and progress == last_progress and !stall_warning_displayed) {
            if (progress == 0) {
                std.debug.print("Download hasn't started yet. Peers might be keeping us choked. Retrying...\n", .{});
            } else {
                std.debug.print("Download seems stalled. No progress in 30 seconds.\n", .{});
            }
            stall_warning_displayed = true;
        }

        std.time.sleep(1_000_000_000); // 1 second
    }

    std.debug.print("Download completed successfully!\n", .{});
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

// Thread function to connect to remaining peers in the background
fn connectRemainingPeers(peer_manager: *network.PeerManager, peers: []const net.Address) void {
    for (peers) |peer_addr| {
        std.debug.print("Connecting to additional peer {}\n", .{peer_addr});
        peer_manager.connectToPeer(peer_addr) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
            continue;
        };
    }
    std.debug.print("Finished connecting to additional peers\n", .{});
}
