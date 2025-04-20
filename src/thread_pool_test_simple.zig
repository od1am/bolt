const std = @import("std");
const ThreadPool = @import("thread_pool.zig").ThreadPool;
const Task = @import("thread_pool.zig").Task;
const testing = std.testing;

// Simple counter for testing
const SimpleCounter = struct {
    value: std.atomic.Value(usize),
    
    fn increment(ctx: *anyopaque) void {
        const self = @as(*SimpleCounter, @ptrCast(@alignCast(ctx)));
        _ = self.value.fetchAdd(1, .monotonic);
        // Add a small delay to simulate work
        std.time.sleep(10 * std.time.ns_per_ms);
    }
};

test "ThreadPool basic functionality" {
    // Create a thread pool with 4 threads
    var pool = try ThreadPool.init(testing.allocator, 4, 100);
    defer pool.deinit();
    
    var counter = SimpleCounter{ .value = std.atomic.Value(usize).init(0) };
    
    // Submit 10 tasks
    for (0..10) |_| {
        try pool.submit(Task{
            .function = SimpleCounter.increment,
            .context = &counter,
        });
    }
    
    // Wait for all tasks to complete
    while (pool.getActiveTaskCount() > 0 or pool.getQueuedTaskCount() > 0) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }
    
    // Check the result
    try testing.expectEqual(@as(usize, 10), counter.value.load(.monotonic));
}
