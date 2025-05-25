const std = @import("std");
const Thread = @import("std").Thread;
const root = @import("root.zig");
const Server = root.AsyncTcpListener(10, *AppData);
const Connection = root.Connection;
const Telemetry = root.Telemetry;

const print = std.debug.print;

fn log_handler(watcher: *Telemetry) !void {
    const project_dir = try std.fs.cwd().openDir("..", .{});

    project_dir.makeDir("results") catch |err| {
        switch (err) {
            std.posix.MakeDirError.PathAlreadyExists => {},
            else => return err,
        }
    };

    const output_dir = try project_dir.openDir("results", .{});

    const csv = try output_dir.createFile("zig.csv", .{});
    defer csv.close();

    _ = try csv.write("total,finished,average,min,max\n");

    while (true) {
        const data = watcher.GetData();
        print("\x1b[2J\x1b[H\x1b[32mConnections: {}/sec\n Finished Connections: {}/sec\n Average Latency: {d:.3}ms\n Lowest Latency: {d:.3}ms\n Highest latency {d:.3}ms\n\x1b[0m", data);

        var buff: [128]u8 = undefined;
        _ = try csv.write(try std.fmt.bufPrint(&buff, "{},{},{},{},{}\n", data));

        std.time.sleep(1 * std.time.ns_per_s);
    }
}

fn server_handle(conn: *Server.PoolData) anyerror!void {
    switch (conn.connection.tag) {
        .CONNECTED => {
            conn.data.map_lock.lock();
            defer conn.data.map_lock.unlock();

            const id = try conn.data.watcher.WatchConnection();
            try conn.data.connectionid_to_timeid.put(conn.connection.id, id);

            _ = conn.connection.connection.stream.write("HI\n") catch {};
        },
        .CLOSED => {
            conn.data.map_lock.lock();
            defer conn.data.map_lock.unlock();

            const id = conn.data.connectionid_to_timeid.get(conn.connection.id).?;

            conn.data.watcher.StopWatchingConnection(id) catch |err| {
                print("Error: {}", .{err});
            };
        },
        .DATA => {
            var buf: [124]u8 = undefined;
            const reader = conn.connection.connection.stream.reader();
            while (true) {
                const size = reader.read(&buf) catch break;
                if (size == 0) {
                    break;
                }
            }
        },
    }
}

const AppData = struct {
    watcher: *Telemetry,
    connectionid_to_timeid: std.AutoHashMap(u32, u32),
    map_lock: Thread.Mutex = Thread.Mutex{},
};

//TODO: Reduce memory usage when no connections and not task to do
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();

    defer {
        switch (gpa.deinit()) {
            .leak => print("Leaked Memory\n", .{}),
            .ok => print("No leaks\n", .{}),
        }
    }

    var watcher = try Telemetry.init(allocator);
    defer watcher.deinit();

    var data = AppData{ .watcher = &watcher, .connectionid_to_timeid = std.AutoHashMap(u32, u32).init(allocator) };

    _ = try Thread.spawn(.{}, log_handler, .{&watcher});

    var server = try Server
        .init(
        [4]u8{ 127, 0, 0, 1 },
        8080,
        allocator,
        128,
        server_handle,
    );
    defer server.deinit();

    try server.serve(-1, &data);

    data.connectionid_to_timeid.deinit();
}
