const std = @import("std");
const Timer = std.time.Timer;
const Mutex = std.Thread.Mutex;

const TelemetryErrors = error{
    NullTimerIndex,
    NoConnectionEntry,
    ConnectionFinishedAlready,
};

pub const Telemetry = struct {
    processing: std.ArrayList(?Timer),
    finished: std.ArrayList(?u64),
    processing_mut: Mutex = Mutex{},
    finished_mut: Mutex = Mutex{},

    pub fn init(allocator: std.mem.Allocator) anyerror!Telemetry {
        var processing = std.ArrayList(?Timer).init(allocator);
        try processing.ensureTotalCapacity(40);
        var finished = std.ArrayList(?u64).init(allocator);
        try finished.ensureTotalCapacity(40);
        return Telemetry{
            .processing = processing,
            .finished = finished,
        };
    }

    //needs mutex
    //sets timer for connection and returns the id for the new connection
    pub fn WatchConnection(self: *Telemetry) !u32 {
        self.processing_mut.lock();
        defer self.processing_mut.unlock();
        for (self.processing.items, 0..) |timer, index| {
            if (timer == null) {
                self.processing.items[index] = try Timer.start();
                return @intCast(index);
            }
        }
        const ptr = try self.processing.addOne();
        ptr.* = try Timer.start();
        return @intCast(self.processing.items.len - 1);
    }

    pub fn StopWatchingConnection(self: *Telemetry, id: u32) anyerror!void {
        self.finished_mut.lock();
        defer self.finished_mut.unlock();

        var timer = self.processing.items[id] orelse {
            return TelemetryErrors.NoConnectionEntry;
        };
        defer self.processing.items[id] = null;

        //assumes there is an empty spot associated with the id,
        //If not, adds new entry
        if (self.finished.items.len > id) {
            self.finished.items[id] = timer.lap();
        } else {
            const ptr = try self.finished.addOne();
            ptr.* = timer.lap();
        }
    }

    //calculates average latency and throughtput. Also clears finished connections from watchlist
    pub fn GetData(self: *Telemetry) struct { u64, u64, u64, u64, u64 } {
        var connections: u64 = 0;
        //////Critical Section
        self.finished_mut.lock();
        self.processing_mut.lock();
        for (self.processing.items) |timer| {
            if (timer != null) {
                connections += 1;
            }
        }

        var total_latency: u64 = 0;
        var finished_connections: u64 = 0;

        var min_latency: u64 = 0;
        var max_latency: u64 = 0;

        for (self.finished.items, 0..) |time_entry, index| {
            if (time_entry) |stop_time| {
                //get min/max latency and avrg latency
                if (stop_time > max_latency) {
                    max_latency = stop_time;
                }
                if (index == 0 or stop_time < min_latency) {
                    min_latency = stop_time;
                }

                connections += 1;
                total_latency += stop_time;
                finished_connections += 1;

                //remove finish time for connection
                self.finished.items[index] = null;
            }
        }
        self.processing_mut.unlock();
        self.finished_mut.unlock();
        ///////////////////////////////
        const avrg_latency = if (finished_connections != 0) total_latency / finished_connections else 0;
        return .{
            connections,
            finished_connections,
            avrg_latency / std.time.ns_per_ms,
            min_latency / std.time.ns_per_ms,
            max_latency / std.time.ns_per_ms,
        };
    }

    pub fn deinit(self: *Telemetry) void {
        self.finished.deinit();
        self.processing.deinit();
    }
};
