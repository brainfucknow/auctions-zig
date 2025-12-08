const std = @import("std");
const api = @import("api.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const events_file = std.process.getEnvVarOwned(allocator, "EVENTS_FILE") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk try allocator.dupe(u8, "tmp/events.jsonl");
        }
        return err;
    };
    defer allocator.free(events_file);

    var app_state = try api.AppState.init(allocator, events_file);
    defer app_state.deinit();

    const port: u16 = if (std.process.getEnvVarOwned(allocator, "PORT")) |port_str| blk: {
        defer allocator.free(port_str);
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 8080;
    } else |_| 8080;

    const address = try std.net.Address.parseIp("0.0.0.0", port);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.debug.print("Server listening on http://0.0.0.0:{d}\n", .{port});

    while (true) {
        const connection = try listener.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ allocator, &app_state, connection });
        thread.detach();
    }
}

fn handleConnection(allocator: std.mem.Allocator, state: *api.AppState, connection: std.net.Server.Connection) void {
    defer connection.stream.close();
    handleConnectionInner(allocator, state, connection) catch |err| {
        std.debug.print("Connection error: {}\n", .{err});
    };
}

fn handleConnectionInner(allocator: std.mem.Allocator, state: *api.AppState, connection: std.net.Server.Connection) !void {
    var buffer: [4096]u8 = undefined;
    const bytes_read = try connection.stream.read(&buffer);

    if (bytes_read == 0) return;

    const request_str = buffer[0..bytes_read];

    // Parse HTTP request line
    var line_it = std.mem.splitScalar(u8, request_str, '\n');
    const first_line = line_it.next() orelse return error.InvalidRequest;

    var parts_it = std.mem.splitScalar(u8, first_line, ' ');
    const method_str = parts_it.next() orelse return error.InvalidRequest;
    const path = parts_it.next() orelse return error.InvalidRequest;

    const method = std.meta.stringToEnum(std.http.Method, method_str) orelse .GET;

    // Find JWT header
    var jwt_payload: ?[]const u8 = null;
    while (line_it.next()) |line| {
        if (line.len <= 1) break; // Empty line means end of headers
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) break;

        const colon_pos = std.mem.indexOf(u8, trimmed, ":") orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, trimmed[colon_pos+1..], &std.ascii.whitespace);

        if (std.ascii.eqlIgnoreCase(name, "x-jwt-payload")) {
            jwt_payload = value;
        }
    }

    // Handle request
    const response_body = api.handleRequest(
        allocator,
        state,
        method,
        path,
        jwt_payload,
        "",
    ) catch |err| {
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"message\":\"{s}\"}}", .{@errorName(err)});
        defer allocator.free(error_msg);

        const status_code: u16 = switch (err) {
            error.Unauthorized => 401,
            else => 400,
        };

        const response = try std.fmt.allocPrint(allocator,
            "HTTP/1.1 {d} Error\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
            .{status_code, error_msg.len, error_msg}
        );
        defer allocator.free(response);

        _ = try connection.stream.write(response);
        return;
    };
    defer allocator.free(response_body);

    const response = try std.fmt.allocPrint(allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{response_body.len, response_body}
    );
    defer allocator.free(response);

    _ = try connection.stream.write(response);
}

test "simple test" {
    var list = std.array_list.Managed(i32).init(std.testing.allocator);
    defer list.deinit();
    try std.testing.expectEqual(@as(i32, 42), 42);
}
