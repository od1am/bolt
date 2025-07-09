const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const config = @import("config.zig");
const torrent = @import("torrent.zig");
const network = @import("networking.zig");
const PieceManager = @import("piece_manager.zig").PieceManager;
const FileIO = @import("file_io.zig").FileIO;
const tracker = @import("tracker.zig");
const Metrics = @import("metrics.zig").Metrics;
const net = std.net;
const posix = std.posix;
const os = std.os;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var conf = cli.parseArgs(allocator) catch |err| {
        if (err == error.HelpRequested or err == error.InvalidArguments) {
            return;
        }
        return err;
    };
    defer conf.deinit(allocator);

    const data = try std.fs.cwd().readFileAlloc(allocator, conf.torrent_path, std.math.maxInt(usize));
    defer allocator.free(data);
    var torrent_file = try torrent.parseTorrentFile(allocator, data);
    defer torrent_file.deinit(allocator);

    // Print announce URL and announce-list for debugging
    if (torrent_file.announce_url) |url| {
        std.debug.print("Announce URL: {s}\n", .{url});
    } else {
        std.debug.print("No announce URL found\n", .{});
    }

    if (torrent_file.announce_list) |announce_list| {
        std.debug.print("Found {} alternate trackers:\n", .{announce_list.len});
        for (announce_list, 0..) |url, i| {
            std.debug.print("  {}: {s}\n", .{ i, url });
        }
    } else {
        std.debug.print("No alternate trackers found\n", .{});
    }

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

    // Create metrics collector
    var metrics = Metrics.init(allocator);
    defer metrics.deinit();

    const total_size = if (torrent_file.info.length) |len| len else blk: {
        var sum: usize = 0;
        for (files) |file| sum += file.length;
        break :blk sum;
    };

    var piece_manager = try PieceManager.init(
        allocator,
        torrent_file.info.piece_length,
        torrent_file.info.pieces.len / 20,
        total_size,
        try parsePieceHashes(allocator, torrent_file.info.pieces),
        output_file_path orelse "temp_data", // Use a placeholder if multi-file
        &metrics,
    );
    defer piece_manager.deinit();

    // Connect the FileIO to the PieceManager
    piece_manager.setFileIO(&file_io);

    const info_hash = try torrent_file.calculateInfoHash();
    // Create a simplified peer manager without thread pool to avoid issues
    var peer_manager = try network.PeerManager.initSimple(
        allocator,
        torrent_file,
        &piece_manager,
        &file_io,
        conf.peer_id,
        info_hash,
    );
    defer peer_manager.deinit();

    std.debug.print("Requesting peers from tracker...\n", .{});

    const params = tracker.RequestParams{
        .info_hash = info_hash,
        .peer_id = conf.peer_id,
        .port = conf.listen_port,
        .amount_uploaded = 0,
        .amount_downloaded = 0,
        .left = total_size,
        .compact = true,
    };

    // Attempt to connect to trackers
    var tracker_response: ?tracker.Response = null;

    tracker_connect: {

        // Add default trackers if none are found
        var default_trackers = std.ArrayList([]const u8).init(allocator);
        defer default_trackers.deinit();

        if (torrent_file.announce_url == null and (torrent_file.announce_list == null or torrent_file.announce_list.?.len == 0)) {
            std.debug.print("No trackers found in torrent file, adding default trackers\n", .{});

            // Add some default trackers - prioritize more reliable ones
            try default_trackers.append(try allocator.dupe(u8, "udp://tracker.opentrackr.org:1337"));
            try default_trackers.append(try allocator.dupe(u8, "udp://tracker.openbittorrent.com:80"));
            try default_trackers.append(try allocator.dupe(u8, "udp://exodus.desync.com:6969"));
            try default_trackers.append(try allocator.dupe(u8, "udp://open.stealth.si:80"));
            try default_trackers.append(try allocator.dupe(u8, "udp://tracker.coppersurfer.tk:6969"));
            try default_trackers.append(try allocator.dupe(u8, "udp://tracker.leechers-paradise.org:6969"));

            // Set as announce list
            torrent_file.announce_list = try default_trackers.toOwnedSlice();
        }

        // Try to connect to the main tracker if available
        if (torrent_file.announce_url) |announce_url| {
            std.debug.print("Trying primary tracker: {s}...\n", .{announce_url});
            if (tracker.requestPeersWithUrl(allocator, announce_url, params, "")) |response| {
                tracker_response = response;
                std.debug.print("Successfully connected to primary tracker, starting download...\n", .{});
                // We have a successful tracker response, proceed with download
                break :tracker_connect;
            } else |err| {
                std.debug.print("Failed to connect to primary tracker: {}\n", .{err});
                // Just continue with null tracker_response
            }
        }

        // If primary tracker failed or doesn't exist, try alternate trackers
        if (tracker_response == null and torrent_file.announce_list != null and torrent_file.announce_list.?.len > 0) {
            std.debug.print("Trying alternate trackers...\n", .{});

            for (torrent_file.announce_list.?) |announce_url| {
                std.debug.print("Trying tracker: {s}\n", .{announce_url});

                if (tracker.requestPeersWithUrl(allocator, announce_url, params, "")) |response| {
                    tracker_response = response;
                    std.debug.print("Successfully connected to alternate tracker, starting download...\n", .{});
                    // We have a successful tracker response, proceed with download
                    break :tracker_connect;
                } else |alt_err| {
                    std.debug.print("Failed to connect to alternate tracker: {}\n", .{alt_err});
                    continue;
                }
            }
        }

        // If all trackers failed, return error
        if (tracker_response == null) {
            std.debug.print("Failed to connect to any trackers\n", .{});
            return error.AllTrackersConnectionFailed;
        }
    } // End of tracker_connect block

    defer allocator.free(tracker_response.?.peers);

    std.debug.print("Received {} bytes of peer data from tracker\n", .{tracker_response.?.peers.len});

    const peers = try network.parseCompactPeers(allocator, tracker_response.?.peers);
    defer allocator.free(peers);

    std.debug.print("Found {} peers\n", .{peers.len});

    var successful_connections: usize = 0;
    const max_initial_connections = 20; // Try more peers initially
    var started_download = false;

    std.debug.print("Attempting to connect to peers...\n", .{});

    // Try to connect to peers with retry logic
    var connection_attempts: usize = 0;
    const max_connection_attempts = @min(peers.len, 50); // Don't try too many peers

    while (successful_connections < 3 and connection_attempts < max_connection_attempts) {
        const peer_index = connection_attempts % peers.len;
        const peer_addr = peers[peer_index];

        std.debug.print("Connecting to peer {} ({}/{})\n", .{ peer_addr, connection_attempts + 1, max_connection_attempts });

        peer_manager.connectToPeer(peer_addr) catch |err| {
            std.debug.print("Failed to connect to peer: {}\n", .{err});
            connection_attempts += 1;
            continue;
        };

        successful_connections += 1;
        std.debug.print("Successfully connected to {} peers so far\n", .{successful_connections});

        // Start the download as soon as we connect to the first successful peer
        if (successful_connections == 1 and !started_download) {
            std.debug.print("Starting download with first successful peer\n", .{});
            peer_manager.startDownload() catch |err| {
                std.debug.print("Failed to start download with first peer: {}\n", .{err});
                // Continue trying with more peers instead of giving up
                connection_attempts += 1;
                continue;
            };
            started_download = true;
        }

        connection_attempts += 1;

        // Small delay between connection attempts to avoid overwhelming peers
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    if (successful_connections == 0) {
        std.debug.print("Failed to connect to any peers after {} attempts, exiting\n", .{connection_attempts});
        return;
    }

    std.debug.print("Connected to {} peers\n", .{successful_connections});

    // If we haven't started the download yet (which is unlikely), start it now
    if (!started_download) {
        std.debug.print("Starting download now\n", .{});
        peer_manager.startDownload() catch |err| {
            std.debug.print("Failed to start download: {}\n", .{err});
            // Try to connect to more peers and retry
            if (successful_connections < peers.len) {
                std.debug.print("Attempting to connect to more peers...\n", .{});
                const retry_start = @min(max_initial_connections, successful_connections + 1);
                const retry_end = @min(peers.len, retry_start + 10);

                for (peers[retry_start..retry_end]) |peer_addr| {
                    peer_manager.connectToPeer(peer_addr) catch continue;
                    successful_connections += 1;
                }

                // Try to start download again
                peer_manager.startDownload() catch |retry_err| {
                    std.debug.print("Failed to start download after retry: {}\n", .{retry_err});
                    return;
                };
            } else {
                return;
            }
        };
        started_download = true;
    }

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
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const random = rng.random();

    // Download retry logic
    var download_retry_count: usize = 0;
    const max_download_retries = 3;
    var last_successful_download_time = std.time.milliTimestamp();
    const download_stall_timeout = 120 * 1000; // 2 minutes without progress

    while (!piece_manager.isDownloadComplete()) {
        const current_time = std.time.milliTimestamp();

        // Check for download stall and retry if necessary
        if (current_time - last_successful_download_time > download_stall_timeout) {
            download_retry_count += 1;
            std.debug.print("Download appears stalled, attempting retry {}/{}\n", .{ download_retry_count, max_download_retries });

            if (download_retry_count <= max_download_retries) {
                // Try to connect to more peers
                const remaining_peers = peers.len - connect_index;
                if (remaining_peers > 0) {
                    const retry_count = @min(remaining_peers, 5);
                    std.debug.print("Connecting to {} additional peers for retry\n", .{retry_count});

                    for (peers[connect_index .. connect_index + retry_count]) |peer_addr| {
                        peer_manager.connectToPeer(peer_addr) catch continue;
                        successful_connections += 1;
                    }
                    connect_index += retry_count;

                    // Try to restart download
                    peer_manager.startDownload() catch |retry_err| {
                        std.debug.print("Failed to restart download: {}\n", .{retry_err});
                    };
                }

                last_successful_download_time = current_time;
            } else {
                std.debug.print("Maximum retry attempts reached, download may be stuck\n", .{});
                break;
            }
        }

        // Update last successful download time if we made progress
        if (piece_manager.downloaded_pieces > last_download_count) {
            last_successful_download_time = current_time;
            download_retry_count = 0; // Reset retry count on progress
        }

        // Periodically request new peers from the tracker
        if (current_time - last_tracker_time > tracker_update_interval) {
            std.debug.print("Requesting updated peer list from tracker...\n", .{});

            const updated_params = tracker.RequestParams{
                .info_hash = info_hash,
                .peer_id = conf.peer_id,
                .port = conf.listen_port,
                .amount_uploaded = 0,
                .amount_downloaded = piece_manager.downloaded_pieces * piece_manager.piece_length,
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

            // Print detailed metrics
            peer_manager.printMetrics();

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
