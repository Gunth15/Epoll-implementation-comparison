//Thread pool for server
const std = @import("std");
const Thread = std.Thread;

const QError = error{
    NoTaskAvailable,
};

//Controls its own areana allocator
//Allows single producer to write at all times
//TODO: Implement Michael Scott Algorithm
pub fn MPSCQueue(comptime T: type) type {
    return struct {
        const WorkQueue = std.SinglyLinkedList(T);
        const Self = @This();

        work_queue: WorkQueue,
        queue_mutex: Thread.Mutex,
        allocator: std.mem.Allocator,
        tail: ?*std.SinglyLinkedList(T).Node = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .queue_mutex = Thread.Mutex{}, .work_queue = WorkQueue{}, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            while (self.work_queue.len() > 0) {
                const node = self.work_queue.popFirst() orelse unreachable;
                self.allocator.destroy(node);
            }
        }

        pub fn enqueue(self: *Self, payload: T) std.mem.Allocator.Error!void {
            const node = try self.allocator.create(WorkQueue.Node);
            node.*.data = payload;
            //If there is a tail, place after tail
            //Else make new element the head
            if (self.tail) |task| {
                task.insertAfter(node);
            } else {
                //head and tail are set to same element
                self.work_queue.prepend(node);
            }
            self.tail = node;
            return;
        }

        //Dequeued items are owned by the caller after removal
        pub fn dequeue(self: *Self) ?T {
            if (self.work_queue.first) |_| {
                //copies memory back to stack
                const node = self.work_queue.popFirst() orelse unreachable;
                const data = node.*;

                defer self.allocator.destroy(node);
                if (self.tail == node) {
                    self.tail = null;
                }

                return data.data;
            } else {
                //Queue is empty, set head to tail
                return null;
            }
        }
        pub fn is_empty(self: Self) bool {
            return self.work_queue.first == null;
        }
        pub fn lock(self: *Self) void {
            self.queue_mutex.lock();
        }
        pub fn unlock(self: *Self) void {
            self.queue_mutex.unlock();
        }
    };
}

const RingBufferError = error{
    BufferFull,
    BufferEmpty,
};

//fixed size circular queue. Thread safe
pub fn RingBuffer(T: type, comptime size: u32) type {
    return struct {
        const Self = @This();
        //switch these to ?u32
        head: ?u64 = null,
        tail: ?u64 = null,
        data: [size]T = [_]T{undefined} ** size,
        mut: Thread.Mutex = Thread.Mutex{},

        pub fn enqueue(self: *Self, payload: T) RingBufferError!void {
            //Get index of tail. If the tail is equal to the head, buffer is considered full
            if (self.isFull()) return RingBufferError.BufferFull;

            const next = if (self.tail) |tail| (tail + 1) % self.data.len else 0;
            self.data[@intCast(next)] = payload;
            self.tail = next;

            if (self.isEmpty()) {
                self.head = self.tail;
            }
        }
        pub fn dequeue(self: *Self) RingBufferError!T {
            if (self.isEmpty()) return RingBufferError.BufferEmpty;

            defer {
                //if head and tail have same index, queue considered empty
                if (self.head == self.tail) {
                    self.head = null;
                    self.tail = null;
                } else {
                    self.data[@intCast(self.head.?)] = undefined;
                    self.head = (self.head.? + 1) % self.data.len;
                }
            }

            return self.data[@intCast(self.head.?)];
        }
        pub fn steal(self: *Self) RingBufferError!T {
            if (self.isEmpty()) {
                return RingBufferError.BufferEmpty;
            }
            //
            defer //if head and tail have same index, queue considered empty
            if (self.head == self.tail) {
                self.head = null;
                self.tail = null;
            } else {
                self.data[@intCast(self.tail.?)] = undefined;
                self.tail = (self.tail.? + self.data.len - 1) % self.data.len;
            };
            return self.data[@intCast(self.tail.?)];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }
        pub fn isFull(self: *const Self) bool {
            return self.head != null and self.tail != null and ((self.tail.? + 1) % self.data.len == self.head.?);
        }
        pub fn lock(self: *Self) void {
            self.mut.lock();
        }
        pub fn unlock(self: *Self) void {
            self.mut.unlock();
        }
    };
}

//Thread Pool
//features...
///global queue
//local queues
//Work staeling
//
// A key componenets was to determine most of the beahavior at runtime.
// Becasue of this, You are to pass this one function and one type(posissbly union)
// the implementation from their is left up to the developer
pub fn ThreadPool(pool_size: comptime_int, TaskData: type) type {
    const LocalBuff = RingBuffer(TaskData, pool_size);
    return struct {
        pub const Task = *const fn (*TaskData) anyerror!void;
        const Self = @This();
        global: MPSCQueue(TaskData),
        local_queues: [pool_size]LocalBuff = [_]LocalBuff{LocalBuff{}} ** pool_size,
        threads: [pool_size]Thread = undefined,
        thread_status: [pool_size]ThreadStatus = [_]ThreadStatus{ThreadStatus.WAITING} ** pool_size,
        status_con: Thread.Condition = Thread.Condition{},
        exec_task: Task,

        const ThreadStatus = enum { WORKING, WAITING, ABORT };
        const InitWorker = struct { context: *Self, id: u32 };

        //Starts threads and creates task queue
        pub fn init(allocator: std.mem.Allocator, main_task: Task) Self {
            return Self{ .exec_task = main_task, .global = MPSCQueue(TaskData).init(allocator) };
        }

        //Dispatches threads
        pub fn dispatch(self: *Self) !void {
            for (0..pool_size) |id| {
                // create thread and change status
                self.thread_status[id] = ThreadStatus.WORKING;
                self.threads[id] = try Thread.spawn(.{}, Self.work_handler, .{InitWorker{ .context = self, .id = @intCast(id) }});
            }
        }

        //enqueues task and wakes up sleeping(waiting) threads
        pub fn enqueue(self: *Self, task_data: TaskData) anyerror!void {
            self.global.lock();
            defer self.global.unlock();

            try self.global.enqueue(task_data);

            self.status_con.broadcast();
        }

        //waits for threads to finish
        pub fn wait(self: *Self) void {
            for (self.threads) |thread| {
                thread.join();
            }
        }

        pub fn deinit(self: *Self) void {
            for (&self.thread_status) |*status| {
                status.* = ThreadStatus.ABORT;
            }
            self.status_con.broadcast();
            self.wait();
            self.global.deinit();
        }

        fn work_handler(args: InitWorker) anyerror!void {
            var timeout: u32 = 0;
            var counter: u32 = 0;
            var local = &args.context.local_queues[args.id];
            while (true) {
                switch (args.context.thread_status[args.id]) {
                    ThreadStatus.ABORT => break,
                    ThreadStatus.WAITING => {
                        //Wait until signaled then immediately released
                        var mut = Thread.Mutex{};
                        mut.lock();
                        defer mut.unlock();
                        args.context.status_con.wait(&mut);
                        //May have to check if ABORT has been called just in case
                        args.context.thread_status[args.id] =
                            if (args.context.thread_status[args.id] != ThreadStatus.ABORT)
                                ThreadStatus.WORKING
                            else
                                ThreadStatus.ABORT;
                    },
                    ThreadStatus.WORKING => {
                        if (counter % 61 == 0) {
                            defer args.context.global.unlock();
                            defer local.unlock();
                            args.context.global.lock();
                            local.lock();

                            if (!args.context.global.is_empty() and !local.isFull()) {
                                try local.enqueue(args.context.global.dequeue().?);
                            }
                        }

                        //global poll counter
                        counter += 1;

                        local.lock();
                        //if queue not empty, do work
                        if (!local.isEmpty()) {
                            defer local.unlock();
                            var task = try local.dequeue();
                            timeout = 0;
                            args.context.exec_task(&task) catch |err| {
                                std.debug.print("Thread {} Error: {}", .{ args.id, err });
                            };
                        } else {
                            //else steal work
                            local.unlock();
                            for (0..args.context.local_queues.len) |t_id| {
                                if (t_id == args.id) continue;
                                //Shortest Id takes priority thus we wait on smallest id to finish
                                if (t_id < args.id) {
                                    defer args.context.local_queues[t_id].unlock();
                                    args.context.local_queues[t_id].lock();
                                    defer local.unlock();
                                    local.lock();
                                    if (!args.context.local_queues[t_id].isEmpty() and !local.isFull()) {
                                        const task = try args.context.local_queues[t_id].steal();
                                        try local.enqueue(task);
                                    }
                                } else {
                                    defer local.unlock();
                                    local.lock();
                                    defer args.context.local_queues[t_id].unlock();
                                    args.context.local_queues[t_id].lock();
                                    if (!args.context.local_queues[t_id].isEmpty() and !local.isFull()) {
                                        const task = try args.context.local_queues[t_id].steal();
                                        try local.enqueue(task);
                                    }
                                }
                            }
                            timeout += 1;
                            if (timeout == 100) {
                                args.context.thread_status[args.id] = ThreadStatus.WAITING;
                            }
                        }
                    },
                }
            }
        }
    };
}

//const Pool = struct {};
const number_task = struct {
    num: u32,
    pub fn print_num(self: *const number_task) void {
        std.debug.print("Task number {}\n", .{self.num});
    }
    pub fn print_num2(ptr: *anyopaque) anyerror!void {
        const self: *number_task = @ptrCast(@alignCast(ptr));
        std.debug.print("Task number {}\n", .{self.num});
    }
};

fn work_task(num: *const number_task) !void {
    num.print_num();
}

fn make_task(q: *MPSCQueue(number_task)) !void {
    for (0..20) |value| {
        defer q.unlock();
        q.lock();

        const task = number_task{ .num = @intCast(value) };
        try q.enqueue(task);
    }
}

fn do_task(q: *MPSCQueue(number_task)) !void {
    var timer = try std.time.Timer.start();
    while (timer.read() <= 1 * std.time.ns_per_s) {
        defer q.unlock();
        q.lock();
        const task: number_task = q.dequeue() orelse continue;
        task.print_num();
        std.time.sleep(100);
    }
}

test "Thread safe mcsp queue test" {
    var queue = MPSCQueue(number_task).init(std.testing.allocator);
    defer queue.deinit();
    const producer = try Thread.spawn(.{}, make_task, .{&queue});
    defer producer.join();

    var thread_array = [3]Thread{ undefined, undefined, undefined };
    for (0..3) |id| {
        thread_array[id] = try Thread.spawn(.{}, do_task, .{&queue});
    }

    try std.testing.expectEqual(
        null,
        queue.work_queue.first,
    );

    for (thread_array) |thr| {
        thr.join();
    }
}

test "Ring buffer test" {
    var ring_buff = RingBuffer(u32, 3){};
    //Should be empty
    try std.testing.expectError(RingBufferError.BufferEmpty, ring_buff.dequeue());
    std.debug.print("Queue is empty\n", .{});

    //enqueue
    try ring_buff.enqueue(1);
    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    try ring_buff.enqueue(2);
    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    try ring_buff.enqueue(3);
    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    std.debug.print("Numbers enqueued\n", .{});

    //Should be full
    try std.testing.expectError(RingBufferError.BufferFull, ring_buff.enqueue(4));
    std.debug.print("Queue Full\n", .{});

    //Dequeue
    var dq: u32 = try ring_buff.dequeue();
    std.debug.print("DQ: {}\n", .{dq});
    try std.testing.expectEqual(1, dq);

    dq = try ring_buff.dequeue();
    std.debug.print("DQ: {}\n", .{dq});
    try std.testing.expectEqual(2, dq);

    dq = try ring_buff.dequeue();
    std.debug.print("DQ: {}\n", .{dq});
    try std.testing.expectEqual(3, dq);

    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    std.debug.print("Numbers dequeued\n", .{});

    //enqueue, dequeue test
    try ring_buff.enqueue(1);
    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    try std.testing.expectEqual(1, try ring_buff.dequeue());
    try ring_buff.enqueue(3);
    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    try ring_buff.enqueue(3);
    std.debug.print("DATA: {any}\n", .{ring_buff.data});
    try std.testing.expectEqual(3, try ring_buff.dequeue());
    std.debug.print("Numbers randomly dequeued\n", .{});
    //stealy
    dq = try ring_buff.steal();
    std.debug.print("DQ: {}\n", .{dq});
    try std.testing.expectEqual(3, dq);
    std.debug.print("Number stollen\n", .{});
}

test "Thread Pool" {
    var pool = ThreadPool(3, number_task).init(std.testing.allocator, work_task);
    std.debug.print("ThreadPool created\n", .{});
    try pool.dispatch();

    //Main Loop
    for (0..500) |i| {
        std.debug.print("Queueing Task {}\n", .{i});
        const num = number_task{ .num = @intCast(i) };
        try pool.enqueue(num);
    }

    std.time.sleep(2 * std.time.ns_per_s);
    //Tells all threads to stop working
    //And dellocate MPSCQueue
    pool.deinit();
    try std.testing.expectEqual(null, pool.global.work_queue.first);
}
