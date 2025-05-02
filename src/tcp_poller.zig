const std = @import("std");
const testing = std.testing;
const net = std.net;
const linux = std.os.linux;
const posix = std.posix;

pub const PollConnection = struct {
    connection: net.Server.Connection,
    id: u32,
    //Tcp poll has three states
    //Connection: recieved new connection to server socket
    //Data: recieved data from connection socket
    //Closed: recieved connection closed status from connection socket
    tag: enum {
        DATA,
        CLOSED,
        CONNECTED,
    },
};

//Watches events on tcp server and handles them based on given params
//This should be thread safe, so takes allocator
//The connection args should be known at creation time and are pased to all connection types.
//Up to user to handler interpretation of data
pub fn TcpPoller(AppData: type) type {
    return struct {
        const Self = @This();

        epoll_fd: i32,
        max_events: u32,
        allocator: std.mem.Allocator,
        connections: std.ArrayList(?PollConnection),

        //Main listen server event that is freed when this object is deinitialized
        server_event: *linux.epoll_event,

        //Tcp poll has three states
        handle: *const fn (*const PollConnection, AppData) anyerror!void = undefined,

        //When initialized, TcpPoller will start listening for connections
        pub fn init(max_events: u32, server: *net.Server, allocator: std.mem.Allocator) !Self {
            var connections = std.ArrayList(?PollConnection).init(allocator);
            try connections.ensureUnusedCapacity(50);

            const epollfd: i32 = @intCast(linux.epoll_create());
            var server_event = linux.epoll_event{
                .data = linux.epoll_data{ .fd = server.stream.handle },
                .events = linux.EPOLL.ET | linux.EPOLL.IN | linux.EPOLL.OUT,
            };

            const self = Self{ .connections = connections, .epoll_fd = epollfd, .allocator = allocator, .server_event = &server_event, .max_events = max_events };

            const err: isize = @bitCast(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, server.stream.handle, self.server_event));
            if (err <= -1) {
                return switch (posix.errno(err)) {
                    .EXIST => PollError.ConnectionExist,
                    .NOMEM => PollError.NoMemory,
                    .BADF => PollError.BadFileDescriptor,
                    else => unreachable,
                };
            }
            return self;
        }
        pub fn deinit(self: *Self) void {
            _ = linux.close(@intCast(self.epoll_fd));
            self.connections.deinit();
        }

        const PollError = error{
            InvalidConnectionID,
            NoMemory,
            BadFileDescriptor,
            ConnectionExist,
        };
        //poll block thread until it recieves events or timeout is reached(returns null on timeout)
        //runs the given handle per request
        pub fn poll(self: *Self, server: *net.Server, timeout: i32, args: AppData) !void {
            const events = try self.wait(timeout);
            defer self.allocator.free(events);

            for (events) |event| {
                //accepts the connection and then uses handler(SHOULD NOT BLOCK)
                if (event.data.fd == server.stream.handle) {
                    const server_connection = try server.accept();

                    var poll_conn = PollConnection{
                        .id = @intCast(0),
                        .connection = server_connection,
                        .tag = .CONNECTED,
                    };

                    //adds to empty slot if available
                    for (self.connections.items, 0..) |conn, index| {
                        if (conn == null) {
                            poll_conn.id = @intCast(index);
                            self.connections.items[index] = poll_conn;
                        }
                    }
                    if (poll_conn.id == 0) {
                        const ptr = try self.connections.addOne();
                        poll_conn.id = @intCast(self.connections.items.len - 1);
                        ptr.* = poll_conn;
                    }

                    try self.handle(&poll_conn, args);
                    try self.add_connection(poll_conn);
                } else if ((event.events & linux.EPOLL.IN) != 0) {
                    const id: u32 = event.data.u32;
                    var connection = self.connections.items[id] orelse {
                        return PollError.InvalidConnectionID;
                    };

                    connection.tag = .DATA;
                    try self.handle(&connection, args);
                }
                //On connection close
                if (event.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0) {
                    const id: u32 = event.data.u32;
                    defer self.connections.items[id] = null;
                    var connection = self.connections.items[id] orelse {
                        return PollError.InvalidConnectionID;
                    };

                    connection.tag = .CLOSED;
                    try self.handle(&connection, args);
                    try self.drop_connection(connection);
                }
            }
        }

        const WaitError = error{
            //event pointed to by event(s) does not have write permission
            NoWritePermission,
            // Interrupted by a signal handler or timoute
            InterruptorTimeout };

        //Wait for new events
        fn wait(self: *Self, timeout: i32) ![]linux.epoll_event {
            std.debug.assert(self.max_events > 0);
            std.debug.assert(timeout >= -1);

            var events: []linux.epoll_event = try self.allocator.alloc(linux.epoll_event, self.max_events);
            errdefer self.allocator.free(events);

            const nfds: isize = @bitCast(linux.epoll_wait(self.epoll_fd, events.ptr, self.max_events, timeout));
            //Handle error if any
            if (nfds <= -1) {
                switch (posix.errno(nfds)) {
                    linux.E.FAULT => return WaitError.NoWritePermission,
                    linux.E.INTR => return WaitError.InterruptorTimeout,
                    else => unreachable,
                }
            }

            if (!self.allocator.resize(events, @bitCast(nfds))) {
                std.debug.print("WARNING: could not resize memory\n", .{});
            }
            return events[0..@bitCast(nfds)];
        }

        //add conection
        fn add_connection(self: *Self, conn: PollConnection) PollError!void {
            var conn_event = linux.epoll_event{
                .data = linux.epoll_data{ .u32 = conn.id },
                .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.HUP | linux.EPOLL.RDHUP,
            };
            const err: isize = @bitCast(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, conn.connection.stream.handle, &conn_event));
            if (err <= -1) {
                return switch (posix.errno(err)) {
                    .EXIST => PollError.ConnectionExist,
                    .NOMEM => PollError.NoMemory,
                    .BADF => PollError.BadFileDescriptor,
                    else => unreachable,
                };
            }
        }
        //drop connection
        fn drop_connection(self: *Self, conn: PollConnection) PollError!void {
            const err: isize = @bitCast(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, conn.connection.stream.handle, null));
            if (err <= -1) {
                return switch (posix.errno(err)) {
                    .EXIST => PollError.ConnectionExist,
                    .NOMEM => PollError.NoMemory,
                    .BADF => PollError.BadFileDescriptor,
                    else => unreachable,
                };
            }
        }
    };
}

//Testing
fn handle(conn: *const PollConnection, _: test_struct) anyerror!void {
    switch (conn.tag) {
        .DATA => std.debug.print("Received data\n", .{}),
        .CONNECTED => std.debug.print("Received connection\n", .{}),
        .CLOSED => std.debug.print("Received closed\n", .{}),
    }
}

fn make_request(address: net.Address) !void {
    const stream = try net.tcpConnectToAddress(address);
    defer stream.close();
    _ = try stream.write("Bababooey");
    std.time.sleep(10000);
    std.debug.print("Closing Stream\n", .{});
}

const test_struct = struct {};

test "poller test" {
    const allocator = std.testing.allocator;

    var server = try net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 8080).listen(.{});
    defer server.deinit();

    var poller = try TcpPoller(test_struct).init(4, &server, allocator);
    defer poller.deinit();

    poller.handle = handle;

    const thread = try std.Thread.spawn(.{}, make_request, .{server.listen_address});
    defer thread.join();

    for (0..5) |_| {
        try poller.poll(&server, 5, test_struct{});
    }
}
