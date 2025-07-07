const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Atomic = std.atomic.Value;

pub const Metrics = struct {
    allocator: Allocator,
    mutex: Mutex,
    bytes_downloaded: Atomic(u64),
    bytes_uploaded: Atomic(u64),
    pieces_downloaded: Atomic(u32),
    pieces_verified: Atomic(u32),
    pieces_failed: Atomic(u32),
    active_peers: Atomic(u32),
    connection_attempts: Atomic(u32),
    successful_connections: Atomic(u32),
    failed_connections: Atomic(u32),
    start_time: i64,
    download_rates: std.ArrayList(u64),
    last_rate_time: i64,
    last_bytes_downloaded: u64,

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

    pub fn deinit(self: *Metrics) void {
        self.download_rates.deinit();
    }

    pub fn recordBytesDownloaded(self: *Metrics, bytes: u64) void {
        _ = self.bytes_downloaded.fetchAdd(bytes, .monotonic);
    }

    pub fn recordBytesUploaded(self: *Metrics, bytes: u64) void {
        _ = self.bytes_uploaded.fetchAdd(bytes, .monotonic);
    }

    pub fn recordPieceDownloaded(self: *Metrics) void {
        _ = self.pieces_downloaded.fetchAdd(1, .monotonic);
    }

    pub fn recordPieceVerified(self: *Metrics) void {
        _ = self.pieces_verified.fetchAdd(1, .monotonic);
    }

    pub fn recordPieceFailed(self: *Metrics) void {
        _ = self.pieces_failed.fetchAdd(1, .monotonic);
    }

    pub fn recordConnectionAttempt(self: *Metrics) void {
        _ = self.connection_attempts.fetchAdd(1, .monotonic);
    }

    pub fn recordSuccessfulConnection(self: *Metrics) void {
        _ = self.successful_connections.fetchAdd(1, .monotonic);
        _ = self.active_peers.fetchAdd(1, .monotonic);
    }

    pub fn recordFailedConnection(self: *Metrics) void {
        _ = self.failed_connections.fetchAdd(1, .monotonic);
    }

    pub fn recordPeerDisconnection(self: *Metrics) void {
        _ = self.active_peers.fetchSub(1, .monotonic);
    }

    pub fn updateDownloadRate(self: *Metrics) !void {
        const current_time = std.time.milliTimestamp();
        const current_bytes = self.bytes_downloaded.load(.monotonic);

        const elapsed_seconds = @as(f64, @floatFromInt(current_time - self.last_rate_time)) / 1000.0;

        if (elapsed_seconds >= 1.0) {
            const bytes_delta = current_bytes - self.last_bytes_downloaded;

            const rate = @as(u64, @intFromFloat(@as(f64, @floatFromInt(bytes_delta)) / elapsed_seconds));

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.download_rates.append(rate);
            if (self.download_rates.items.len > 10) {
                _ = self.download_rates.orderedRemove(0);
            }

            self.last_rate_time = current_time;
            self.last_bytes_downloaded = current_bytes;
        }
    }

    pub fn getCurrentDownloadRate(self: *Metrics) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.download_rates.items.len == 0) {
            return 0;
        }

        return self.download_rates.items[self.download_rates.items.len - 1];
    }

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

    pub fn getTotalDownloadTime(self: *Metrics) u64 {
        const current_time = std.time.milliTimestamp();
        return @intCast(@divTrunc(current_time - self.start_time, 1000));
    }

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

test "Metrics basic functionality" {
    const testing = std.testing;

    var metrics = Metrics.init(testing.allocator);
    defer metrics.deinit();

    metrics.recordBytesDownloaded(1024 * 1024); // 1 MB
    metrics.recordPieceDownloaded();
    metrics.recordPieceVerified();
    metrics.recordConnectionAttempt();
    metrics.recordSuccessfulConnection();

    try testing.expectEqual(@as(u64, 1024 * 1024), metrics.bytes_downloaded.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.pieces_downloaded.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.pieces_verified.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.connection_attempts.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.successful_connections.load(.monotonic));
    try testing.expectEqual(@as(u32, 1), metrics.active_peers.load(.monotonic));

    metrics.recordPeerDisconnection();
    try testing.expectEqual(@as(u32, 0), metrics.active_peers.load(.monotonic));
}
