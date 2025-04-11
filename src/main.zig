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
const posix = std.posix;
const os = std.os;

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

    // For multi-file torrents, we'll use the FileIO directly
    // For single-file torrents, we'll still create a temp output file for the PieceManager
    var output_file_path: ?[]const u8 = null;
    defer if (output_file_path != null) allocator.free(output_file_path.?);

    if (torrent_file.info.files == null) {
        // Single file torrent - create the output path for the piece manager
        output_file_path = try std.fs.path.join(allocator, &[_][]const u8{ conf.output_dir, torrent_file.info.name });
    }

    var piece_manager = try PieceManager.init(
        allocator,
        torrent_file.info.piece_length,
        torrent_file.info.pieces.len / 20,
        try parsePieceHashes(allocator, torrent_file.info.pieces),
        output_file_path orelse "temp_data", // Use a placeholder if multi-file
    );
    defer piece_manager.deinit();

    // Connect the FileIO to the PieceManager
    piece_manager.setFileIO(&file_io);

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

    // Attempt to connect to main tracker
    const tracker_response = blk: {
        // Try primary tracker first
        if (tracker.requestPeers(allocator, &torrent_file, params)) |response| {
            std.debug.print("Successfully connected to primary tracker\n", .{});
            break :blk response;
        } else |err| {
            std.debug.print("Failed to connect to tracker: {}\n", .{err});
        }
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
    var last_tracker_time = std.time.milliTimestamp();
    var last_download_count: usize = 0;

    // Tracker update configuration
    const tracker_update_interval = 5 * 60 * 1000; // Update tracker list every 5 minutes
    var peer_list = std.ArrayList(net.Address).init(allocator);
    defer peer_list.deinit();
    for (peers) |peer| {
        try peer_list.append(peer);
    }

    // Number of connections to maintain simultaneously
    var max_connections: usize = 10;
    const max_connections_limit: usize = 30; // Hard limit to avoid too many connections

    // Create a random number generator for better peer selection
    var rng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = rng.random();

    while (!piece_manager.isDownloadComplete()) {
        const current_time = std.time.milliTimestamp();

        // Periodically request new peers from the tracker
        if (current_time - last_tracker_time > tracker_update_interval) {
            std.debug.print("Requesting updated peer list from tracker...\n", .{});

            const updated_params = tracker.RequestParams{
                .info_hash = info_hash,
                .peer_id = conf.peer_id,
                .port = conf.listen_port,
                .uploaded = 0,
                .downloaded = piece_manager.downloaded_pieces * piece_manager.piece_length,
                .left = total_size - (piece_manager.downloaded_pieces * piece_manager.piece_length),
                .compact = true,
            };

            const updated_response = tracker.requestPeers(allocator, &torrent_file, updated_params) catch |err| {
                std.debug.print("Failed to update tracker: {}\n", .{err});
                last_tracker_time = current_time; // Update time anyway to avoid retry spam
                continue; // Skip the rest of this block
            };

            defer allocator.free(updated_response.peers);

            // Add new peers to our list
            const new_peers = try network.parseCompactPeers(allocator, updated_response.peers);
            defer allocator.free(new_peers);

            // Track how many new peers we found
            var new_peer_count: usize = 0;

            // Add each new peer if we don't already have it
            for (new_peers) |new_peer| {
                var is_duplicate = false;

                // Convert new peer to string for comparison
                var new_peer_buf: [100]u8 = undefined;
                const new_peer_str = std.fmt.bufPrint(&new_peer_buf, "{}", .{new_peer}) catch continue;

                for (peer_list.items) |existing_peer| {
                    // Convert existing peer to string
                    var existing_peer_buf: [100]u8 = undefined;
                    const existing_peer_str = std.fmt.bufPrint(&existing_peer_buf, "{}", .{existing_peer}) catch continue;

                    // Compare string representations
                    if (std.mem.eql(u8, new_peer_str, existing_peer_str)) {
                        is_duplicate = true;
                        break;
                    }
                }

                if (!is_duplicate) {
                    try peer_list.append(new_peer);
                    new_peer_count += 1;
                }
            }

            std.debug.print("Added {} new peers from tracker update, now have {} total peers\n", .{ new_peer_count, peer_list.items.len });

            // Reset the connection index if we have new peers
            if (new_peer_count > 0) {
                connect_index = peer_manager.peers.items.len;
            }

            last_tracker_time = current_time;
        }

        // Add more peers every 5 seconds if download is going well
        if (current_time - last_connect_time > 5000 and connect_index < peer_list.items.len) {
            const active_peers = peer_manager.getActivePeerCount();

            // Only add more peers if we're below our target
            if (active_peers < max_connections) {
                var connected_new_peer = false;
                const peers_to_try = @min(3, peer_list.items.len - connect_index); // Try up to 3 peers at once

                var tries: usize = 0;
                while (tries < peers_to_try) : ({
                    tries += 1;
                }) {
                    // Use a random selection strategy for better distribution
                    var selected_index: usize = 0;

                    if (peer_list.items.len - connect_index > 10) {
                        // If we have lots of peers left, pick randomly from the remaining ones
                        selected_index = connect_index + random.intRangeLessThan(usize, 0, peer_list.items.len - connect_index);
                    } else {
                        selected_index = connect_index;
                        connect_index += 1;
                    }

                    // Make sure the selected index is valid
                    if (selected_index >= peer_list.items.len) {
                        break;
                    }

                    const peer_addr = peer_list.items[selected_index];
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

                    // Wait a short time between connection attempts to avoid overwhelming the network
                    std.time.sleep(100 * std.time.ns_per_ms);
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
