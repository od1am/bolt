const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;

/// Metrics for tracking BitTorrent client performance
pub const Metrics = struct {
    /// Allocator used for metrics
    allocator: Allocator,
    /// Mutex for protecting metrics
    mutex: Mutex,
    /// Total bytes downloaded
    bytes_downloaded: Atomic(u64),
    /// Total bytes uploaded
    bytes_uploaded: Atomic(u64),
    /// Number of pieces downloaded
    pieces_downloaded: Atomic(u32),
    /// Number of pieces verified
    pieces_verified: Atomic(u32),
    /// Number of pieces failed verification
    pieces_failed: Atomic(u32),
    /// Number of active peer connections
    active_peers: Atomic(u32),
    /// Number of connection attempts
    connection_attempts: Atomic(u32),
    /// Number of successful connections
    successful_connections: Atomic(u32),
    /// Number of failed connections
    failed_connections: Atomic(u32),
    /// Download start time
    start_time: i64,
    /// Download rates for the last N intervals (bytes/sec)
    download_rates: std.ArrayList(u64),
    /// Last time download rate was calculated
    last_rate_time: i64,
    /// Last bytes downloaded count for rate calculation
    last_bytes_downloaded: u64,

    /// Initialize metrics
    pub fn init(allocator: Allocator) Metrics {
        return Metrics{
            .allocator = allocator,
            .mutex = .{},
            .bytes_downloaded = Atomic(u64).init(0),
            .bytes_uploaded = Atomic(u64).init(0),
            .pieces_downloaded = Atomic(u32).init(0),
            .pieces_verified = Atomic(u32).init(0),
            .pieces_failed = Atomic(u32).init(0),
            .active_peers = Atomic(u32).init(0),
            .connection_attempts = Atomic(u32).init(0),
            .successful_connections = Atomic(u32).init(0),
            .failed_connections = Atomic(u32).init(0),
            .start_time = std.time.milliTimestamp(),
            .download_rates = std.ArrayList(u64).init(allocator),
            .last_rate_time = std.time.milliTimestamp(),
            .last_bytes_downloaded = 0,
        };
    }

    /// Deinitialize metrics
    pub fn deinit(self: *Metrics) void {
        self.download_rates.deinit();
    }

    /// Record bytes downloaded
    pub fn recordBytesDownloaded(self: *Metrics, bytes: u64) void {
        _ = self.bytes_downloaded.fetchAdd(bytes, .monotonic);
    }

    /// Record bytes uploaded
    pub fn recordBytesUploaded(self: *Metrics, bytes: u64) void {
        _ = self.bytes_uploaded.fetchAdd(bytes, .monotonic);
    }

    /// Record a piece downloaded
    pub fn recordPieceDownloaded(self: *Metrics) void {
        _ = self.pieces_downloaded.fetchAdd(1, .monotonic);
    }

    /// Record a piece verified
    pub fn recordPieceVerified(self: *Metrics) void {
        _ = self.pieces_verified.fetchAdd(1, .monotonic);
    }

    /// Record a piece failed verification
    pub fn recordPieceFailed(self: *Metrics) void {
        _ = self.pieces_failed.fetchAdd(1, .monotonic);
    }

    /// Record a connection attempt
    pub fn recordConnectionAttempt(self: *Metrics) void {
        _ = self.connection_attempts.fetchAdd(1, .monotonic);
    }

    /// Record a successful connection
    pub fn recordSuccessfulConnection(self: *Metrics) void {
        _ = self.successful_connections.fetchAdd(1, .monotonic);
        _ = self.active_peers.fetchAdd(1, .monotonic);
    }

    /// Record a failed connection
    pub fn recordFailedConnection(self: *Metrics) void {
        _ = self.failed_connections.fetchAdd(1, .monotonic);
    }

    /// Record a peer disconnection
    pub fn recordPeerDisconnection(self: *Metrics) void {
        _ = self.active_peers.fetchSub(1, .monotonic);
    }

    /// Update download rate
    pub fn updateDownloadRate(self: *Metrics) !void {
        const current_time = std.time.milliTimestamp();
        const current_bytes = self.bytes_downloaded.load(.monotonic);

        // Calculate time elapsed since last update in seconds
        const elapsed_seconds = @as(f64, @floatFromInt(current_time - self.last_rate_time)) / 1000.0;

        // Only update if at least 1 second has passed
        if (elapsed_seconds >= 1.0) {
            // Calculate bytes downloaded since last update
            const bytes_delta = current_bytes - self.last_bytes_downloaded;

            // Calculate download rate in bytes per second
            const rate = @as(u64, @intFromFloat(@as(f64, @floatFromInt(bytes_delta)) / elapsed_seconds));

            self.mutex.lock();
            defer self.mutex.unlock();

            // Add to rates list, keeping only the last 10 rates
            try self.download_rates.append(rate);
            if (self.download_rates.items.len > 10) {
                _ = self.download_rates.orderedRemove(0);
            }

            // Update last values
            self.last_rate_time = current_time;
            self.last_bytes_downloaded = current_bytes;
        }
    }

    /// Get current download rate in bytes per second
    pub fn getCurrentDownloadRate(self: *Metrics) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.download_rates.items.len == 0) {
            return 0;
        }

        return self.download_rates.items[self.download_rates.items.len - 1];
    }

    /// Get average download rate in bytes per second
    pub fn getAverageDownloadRate(self: *Metrics) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.download_rates.items.len == 0) {
            return 0;
        }

        var sum: u64 = 0;
        for (self.download_rates.items) |rate| {
            sum += rate;
        }

        return sum / self.download_rates.items.len;
    }

    /// Get total download time in seconds
    pub fn getTotalDownloadTime(self: *Metrics) u64 {
        const current_time = std.time.milliTimestamp();
        return @intCast(@divTrunc(current_time - self.start_time, 1000));
    }

    /// Print current metrics
    pub fn printMetrics(self: *Metrics) void {
        const bytes_downloaded = self.bytes_downloaded.load(.monotonic);
        const pieces_downloaded = self.pieces_downloaded.load(.monotonic);
        const active_peers = self.active_peers.load(.monotonic);
        const current_rate = self.getCurrentDownloadRate();
        const avg_rate = self.getAverageDownloadRate();
        const total_time = self.getTotalDownloadTime();

        std.debug.print("=== BitTorrent Client Metrics ===\n", .{});
        std.debug.print("Downloaded: {:.2} MB ({} pieces)\n", .{
            @as(f64, @floatFromInt(bytes_downloaded)) / (1024.0 * 1024.0),
            pieces_downloaded,
        });
        std.debug.print("Active peers: {}\n", .{active_peers});
        std.debug.print("Current download rate: {:.2} KB/s\n", .{
            @as(f64, @floatFromInt(current_rate)) / 1024.0,
        });
        std.debug.print("Average download rate: {:.2} KB/s\n", .{
            @as(f64, @floatFromInt(avg_rate)) / 1024.0,
        });
        std.debug.print("Total download time: {}s\n", .{total_time});
        std.debug.print("Connection success rate: {d:.1}%\n", .{
            @as(f64, @floatFromInt(self.successful_connections.load(.monotonic))) /
            @max(1.0, @as(f64, @floatFromInt(self.connection_attempts.load(.monotonic)))) * 100.0,
        });
        std.debug.print("================================\n", .{});
    }
};

// Test the metrics module
test "Metrics basic functionality" {
    const testing = std.testing;

    var metrics = Metrics.init(testing.allocator);
    defer metrics.deinit();

    // Record some metrics
    metrics.recordBytesDownloaded(1024 * 1024); // 1 MB
    metrics.recordPieceDownloaded();
    metrics.recordPieceVerified();
    metrics.recordConnectionAttempt();
    metrics.recordSuccessfulConnection();

    // Check values
    try testing.expectEqual(@as(u64, 1024 * 1024), metrics.bytes_downloaded.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.pieces_downloaded.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.pieces_verified.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.connection_attempts.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.successful_connections.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.active_peers.load(.monotonic));

    // Test peer disconnection
    metrics.recordPeerDisconnection();
    try testing.expectEqual(@as(u32, 0), metrics.active_peers.load(.monotonic));
}
