const std = @import("std");
const testing = std.testing;
const net = std.net;
const linux = std.os.linux;
const posix = std.posix;
const PollerFile = @import("tcp_poller.zig");
const Pool = @import("pool.zig");
const TcpPoller = PollerFile.TcpPoller;
const ThreadPool = Pool.ThreadPool;

pub const Telemetry = @import("interface.zig").Telemetry;
pub const Connection = PollerFile.PollConnection;
pub const Listening = union(enum) { no_conn, conn: Connection };

pub const TcpListener = struct {
    server: net.Server,
    pub fn bind(address: [4]u8, port: u16) !TcpListener {
        const addr = net.Address.initIp4(address, port);
        const server = try net.Address.listen(addr, net.Address.ListenOptions{ .force_nonblocking = true });
        return TcpListener{ .server = server };
    }

    pub fn accept(self: *TcpListener) !Listening {
        return Listening{ .conn = try self.server.accept() };
    }
    pub fn deinit(self: *TcpListener) void {
        self.server.deinit();
    }

    pub fn incoming(self: *TcpListener) !?Listening {
        return self.accept() catch |err| {
            if (err == posix.AcceptError.WouldBlock) return Listening.no_conn;
            return err;
        };
    }
};

pub fn AsyncTcpListener(pool_size: comptime_int, comptime AppData: type) type {
    return struct {
        const Self = @This();
        pub const PoolData = struct {
            data: AppData,
            context: *Self,
            connection: Connection = undefined,
        };
        const ServerPool = ThreadPool(pool_size, PoolData);

        server: net.Server,
        poller: TcpPoller(PoolData),
        allocator: std.mem.Allocator,
        thread_pool: ServerPool,

        //should not block when accetping, max_events is the  maximum amount of events that can be handled per loop
        //Binds to port and initializes thread pool
        pub fn init(address: [4]u8, port: u16, allocator: std.mem.Allocator, comptime max_events: u32, handle: *const fn (*PoolData) anyerror!void) !Self {
            const addr = net.Address.initIp4(address, port);
            var server = try net.Address.listen(addr, net.Address.ListenOptions{ .force_nonblocking = true });
            var poller = try TcpPoller(PoolData).init(max_events, &server, allocator);

            //set default behavior of poller
            poller.handle = enqueue;

            return Self{ .thread_pool = ServerPool.init(allocator, handle), .server = server, .poller = poller, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.poller.deinit();
            self.thread_pool.deinit();
            self.server.deinit();
        }

        //handles connctions
        pub fn serve(self: *Self, timeout: i32, app_data: AppData) !void {
            try self.thread_pool.dispatch();
            const pool_data = PoolData{ .data = app_data, .context = self };
            while (true) {
                self.poller.poll(&self.server, timeout, pool_data) catch |err| {
                    switch (err) {
                        TcpPoller(AppData).WaitError.InterruptorTimeout => continue,
                        else => return err,
                    }
                };
            }
        }

        const Handler = *const fn (conn: *const Connection, app_data: PoolData) anyerror!void;

        fn enqueue(conn: *const Connection, app_data: PoolData) anyerror!void {
            var meta = app_data;
            meta.connection = conn.*;
            try app_data.context.thread_pool.enqueue(meta);
        }
    };
}
