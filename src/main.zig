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
    }

    if (successful_connections == 0) {
        std.debug.print("Failed to connect to any peers, exiting\n", .{});
        return;
    }

    std.debug.print("Starting download with first peer\n", .{});
    try peer_manager.startDownload();

    started_download = true;

    // Set up dynamic peer connection strategy
    var connect_index: usize = max_initial_connections;
    var last_connect_time = std.time.milliTimestamp();
    var next_peer_report_time = std.time.milliTimestamp();
    var last_progress_check_time = std.time.milliTimestamp();
    var last_download_count: usize = 0;

    // Number of connections to maintain simultaneously
    var max_connections: usize = 10;
    const max_connections_limit: usize = 30; // Hard limit to avoid too many connections

    while (!piece_manager.isDownloadComplete()) {
        const current_time = std.time.milliTimestamp();

        // Add more peers every 5 seconds if download is going well
        if (current_time - last_connect_time > 5000 and connect_index < peers.len) {
            const active_peers = peer_manager.getActivePeerCount();

            // Only add more peers if we're below our target
            if (active_peers < max_connections) {
                var connected_new_peer = false;
                const peers_to_try = @min(3, peers.len - connect_index); // Try up to 3 peers at once

                var tries: usize = 0;
                while (tries < peers_to_try) : ({
                    tries += 1;
                    connect_index += 1;
                }) {
                    if (connect_index >= peers.len) break;

                    const peer_addr = peers[connect_index];
                    std.debug.print("Connecting to additional peer {}\n", .{peer_addr});

                    peer_manager.connectToPeer(peer_addr) catch |err| {
                        std.debug.print("Failed to connect to peer: {}\n", .{err});
                        continue;
                    };

                    // Add this peer to the download process
                    const peer_index = peer_manager.peers.items.len - 1;
                    peer_manager.addPeerToDownload(peer_index) catch |err| {
                        std.debug.print("Failed to add peer to download: {}\n", .{err});
                    };

                    connected_new_peer = true;
                }

                if (connected_new_peer) {
                    std.debug.print("Added new peers, now have {} active peers\n", .{peer_manager.getActivePeerCount()});
                }
            }

            last_connect_time = current_time;
        }

        // Print download progress periodically
        if (current_time - next_peer_report_time > 10000) { // Every 10 seconds
            const progress_percentage = @as(f32, @floatFromInt(piece_manager.downloaded_pieces)) /
                @as(f32, @floatFromInt(piece_manager.total_pieces)) * 100.0;

            std.debug.print("Download progress: {d:.1}% ({}/{} pieces) with {} active peers\n", .{ progress_percentage, piece_manager.downloaded_pieces, piece_manager.total_pieces, peer_manager.getActivePeerCount() });

            next_peer_report_time = current_time;
        }

        // Check if download speed is good, adjust max_connections accordingly
        if (current_time - last_progress_check_time > 30000) { // Every 30 seconds
            const new_download_count = piece_manager.downloaded_pieces;
            const pieces_downloaded = new_download_count - last_download_count;
            last_download_count = new_download_count;

            // Adjust connection strategy based on download speed
            if (pieces_downloaded < 5) {
                // Slow download, try more connections
                max_connections = @min(max_connections + 5, max_connections_limit);
                std.debug.print("Download seems slow, increasing max peers to {}\n", .{max_connections});
            } else if (pieces_downloaded > 20 and max_connections > 15) {
                // Fast download, we can reduce connections to save resources
                max_connections -= 2;
                std.debug.print("Download is fast, reducing max peers to {}\n", .{max_connections});
            }

            last_progress_check_time = current_time;
        }

        std.time.sleep(100 * std.time.ns_per_ms); // Small sleep to avoid burning CPU
    }

    std.debug.print("Download complete!\n", .{});
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
