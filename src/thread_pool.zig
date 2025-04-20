const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const Mutex = std.Thread.Mutex;
const debug = std.debug;

/// A task that can be executed by the thread pool
pub const Task = struct {
    /// Function pointer to the task function
    function: *const fn (context: *anyopaque) void,
    /// Context pointer passed to the task function
    context: *anyopaque,
};

/// Helper function to safely peek at the first item in the queue
fn peekItem(fifo: *std.fifo.LinearFifo(Task, .Dynamic)) ?Task {
    if (fifo.readableLength() == 0) return null;

    // Get a copy of the first item without removing it
    const head = fifo.head;
    if (head < fifo.buf.len) {
        return fifo.buf[head];
    }

    return null;
}

/// A thread pool for executing tasks concurrently
pub const ThreadPool = struct {
    /// Allocator used for the thread pool
    allocator: Allocator,
    /// Array of worker threads
    threads: []Thread,
    /// Queue of tasks to be executed
    task_queue: std.fifo.LinearFifo(Task, .Dynamic),
    /// Mutex for protecting the task queue
    queue_mutex: Mutex,
    /// Condition variable for signaling workers
    condition: Thread.Condition,
    /// Flag indicating if the thread pool is shutting down
    shutdown: Atomic(bool),
    /// Number of active tasks
    active_tasks: Atomic(usize),
    /// Maximum number of tasks that can be queued
    max_queue_size: usize,

    /// Initialize a new thread pool with the given number of threads
    pub fn init(allocator: Allocator, thread_count: usize, max_queue_size: usize) !ThreadPool {
        const threads = try allocator.alloc(Thread, thread_count);
        errdefer allocator.free(threads);

        var task_queue = std.fifo.LinearFifo(Task, .Dynamic).init(allocator);
        errdefer task_queue.deinit();

        var pool = ThreadPool{
            .allocator = allocator,
            .threads = threads,
            .task_queue = task_queue,
            .queue_mutex = .{},
            .condition = .{},
            .shutdown = Atomic(bool).init(false),
            .active_tasks = Atomic(usize).init(0),
            .max_queue_size = max_queue_size,
        };

        // Start worker threads
        for (threads, 0..) |*thread, i| {
            thread.* = try Thread.spawn(.{}, workerFunction, .{ &pool, i });
        }

        return pool;
    }

    /// Deinitialize the thread pool and free resources
    pub fn deinit(self: *ThreadPool) void {
        // Signal shutdown
        _ = self.shutdown.swap(true, .monotonic);

        // Wake up all workers
        self.condition.broadcast();

        // Wait for all threads to finish
        for (self.threads) |thread| {
            thread.join();
        }

        // Free resources
        self.allocator.free(self.threads);
        self.task_queue.deinit();
    }

    /// Submit a task to the thread pool
    pub fn submit(self: *ThreadPool, task: Task) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        // Check if we're shutting down
        if (self.shutdown.load(.monotonic)) {
            return error.ThreadPoolShuttingDown;
        }

        // Check if the queue is full
        if (self.task_queue.readableLength() >= self.max_queue_size) {
            return error.QueueFull;
        }

        // Add the task to the queue
        try self.task_queue.writeItem(task);

        // Signal a worker
        self.condition.signal();
    }

    /// Get the number of active tasks
    pub fn getActiveTaskCount(self: *ThreadPool) usize {
        return self.active_tasks.load(.monotonic);
    }

    /// Get the number of queued tasks
    pub fn getQueuedTaskCount(self: *ThreadPool) usize {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        return self.task_queue.readableLength();
    }

    /// Worker thread function
    fn workerFunction(pool: *ThreadPool, worker_id: usize) void {
        debug.print("Worker thread {} started\n", .{worker_id});

        // Use a completely rewritten approach to avoid any potential issues
        while (true) {
            // First check if we should exit
            if (pool.shutdown.load(.monotonic)) {
                break;
            }

            // Try to get a task
            var got_task = false;
            var task: Task = undefined;

            // Critical section with mutex
            pool.queue_mutex.lock();

            // Check if there are tasks in the queue
            if (pool.task_queue.readableLength() > 0) {
                // First peek at the task
                if (peekItem(&pool.task_queue)) |t| {
                    // We found a task, now try to remove it from the queue
                    _ = pool.task_queue.readItem() catch {
                        // If we can't read the item, just continue
                        pool.queue_mutex.unlock();
                        continue;
                    };

                    // Successfully got the task
                    task = t;
                    got_task = true;
                }
            }

            // If no task, wait on condition variable
            if (!got_task) {
                // Only wait if we're not shutting down
                if (!pool.shutdown.load(.monotonic)) {
                    pool.condition.wait(&pool.queue_mutex);
                }
                pool.queue_mutex.unlock();

                // After waiting, go back to the beginning of the loop
                continue;
            }

            // We got a task, unlock and process it
            pool.queue_mutex.unlock();

            // Execute the task
            _ = pool.active_tasks.fetchAdd(1, .monotonic);
            task.function(task.context);
            _ = pool.active_tasks.fetchSub(1, .monotonic);
        }

        debug.print("Worker thread {} exiting\n", .{worker_id});
    }
};


