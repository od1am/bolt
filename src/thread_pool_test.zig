const std = @import("std");
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const Task = @import("thread_pool.zig").Task;
const testing = std.testing;

test "ThreadPool with multiple tasks" {
    // Create a thread pool with 4 threads
    var pool = try ThreadPool.init(testing.allocator, 4, 100);
    defer pool.deinit();

    // Create a counter for testing
    const TestCounter = struct {
        value: std.atomic.Value(usize),

        fn increment(ctx: *anyopaque) void {
            const self = @as(*TestCounter, @ptrCast(@alignCast(ctx)));
            _ = self.value.fetchAdd(1, .monotonic);
            // Add a small delay to simulate work
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    };

    var counter = TestCounter{ .value = std.atomic.Value(usize).init(0) };

    // Submit 20 tasks
    for (0..20) |_| {
        try pool.submit(Task{
            .function = TestCounter.increment,
            .context = &counter,
        });
    }

    // Wait for all tasks to complete
    while (pool.getActiveTaskCount() > 0 or pool.getQueuedTaskCount() > 0) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // Check the result
    try testing.expectEqual(@as(usize, 20), counter.value.load(.monotonic));
}

test "ThreadPool stress test" {
    // Create a thread pool with 8 threads
    var pool = try ThreadPool.init(testing.allocator, 8, 1000);
    defer pool.deinit();

    // Create a shared counter
    const TestSharedCounter = struct {
        value: std.atomic.Value(usize),
        mutex: std.Thread.Mutex,

        fn increment(ctx: *anyopaque) void {
            const self = @as(*TestSharedCounter, @ptrCast(@alignCast(ctx)));
            _ = self.value.fetchAdd(1, .monotonic);

            // Random sleep to create more contention
            const sleep_time = @as(u64, @intCast(std.crypto.random.intRangeAtMost(u32, 1, 20))) * std.time.ns_per_ms;
            std.time.sleep(sleep_time);
        }

        fn incrementWithLock(ctx: *anyopaque) void {
            const self = @as(*TestSharedCounter, @ptrCast(@alignCast(ctx)));
            self.mutex.lock();
            defer self.mutex.unlock();

            const current = self.value.load(.monotonic);

            // Random sleep to create more contention
            const sleep_time = @as(u64, @intCast(std.crypto.random.intRangeAtMost(u32, 1, 10))) * std.time.ns_per_ms;
            std.time.sleep(sleep_time);

            _ = self.value.store(current + 1, .monotonic);
        }
    };

    var counter = TestSharedCounter{
        .value = std.atomic.Value(usize).init(0),
        .mutex = .{},
    };

    // Submit 100 atomic increment tasks
    for (0..100) |_| {
        try pool.submit(Task{
            .function = TestSharedCounter.increment,
            .context = &counter,
        });
    }

    // Submit 100 mutex-protected increment tasks
    for (0..100) |_| {
        try pool.submit(Task{
            .function = TestSharedCounter.incrementWithLock,
            .context = &counter,
        });
    }

    // Wait for all tasks to complete
    while (pool.getActiveTaskCount() > 0 or pool.getQueuedTaskCount() > 0) {
        std.time.sleep(50 * std.time.ns_per_ms);
    }

    // Check the result
    try testing.expectEqual(@as(usize, 200), counter.value.load(.monotonic));
}
