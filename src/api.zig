const std = @import("std");
const models = @import("models.zig");
const domain = @import("domain.zig");
const jwt = @import("jwt.zig");
const persistence = @import("persistence.zig");
const ArrayList = std.array_list.Managed;

const Auction = models.Auction;
const Bid = models.Bid;
const User = models.User;
const Event = models.Event;
const Command = models.Command;
const Repository = domain.Repository;

pub const AppState = struct {
    allocator: std.mem.Allocator,
    repository: Repository,
    mutex: std.Thread.Mutex,
    events_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, events_file: []const u8) !AppState {
        const events = try persistence.readEvents(allocator, events_file);
        defer {
            for (events) |event| {
                event.deinit(allocator);
            }
            allocator.free(events);
        }

        const repo = try persistence.eventsToRepository(allocator, events);

        return AppState{
            .allocator = allocator,
            .repository = repo,
            .mutex = std.Thread.Mutex{},
            .events_file = events_file,
        };
    }

    pub fn deinit(self: *AppState) void {
        var it = self.repository.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.auction.deinit(self.allocator);
            entry.value_ptr.state.deinit(self.allocator);
        }
        self.repository.deinit();
    }
};

pub fn handleRequest(
    allocator: std.mem.Allocator,
    state: *AppState,
    method: std.http.Method,
    path: []const u8,
    jwt_payload: ?[]const u8,
    body: []const u8,
) ![]u8 {

    if (method == .GET and std.mem.eql(u8, path, "/auctions")) {
        return try getAuctionsHandler(allocator, state);
    }

    if (method == .GET and std.mem.startsWith(u8, path, "/auctions/")) {
        const id_str = path[10..];
        if (std.mem.indexOf(u8, id_str, "/") == null) {
            const auction_id = std.fmt.parseInt(i64, id_str, 10) catch {
                return try jsonError(allocator, "Invalid auction ID");
            };
            return try getAuctionHandler(allocator, state, auction_id);
        }
    }

    if (method == .POST and std.mem.eql(u8, path, "/auctions")) {
        const user = try authenticateRequest(allocator, jwt_payload);
        defer user.deinit(allocator);
        return try createAuctionHandler(allocator, state, user, body);
    }

    if (method == .POST and std.mem.startsWith(u8, path, "/auctions/")) {
        var it = std.mem.splitScalar(u8, path[10..], '/');
        const id_str = it.next() orelse return try jsonError(allocator, "Invalid path");
        const next = it.next() orelse return try jsonError(allocator, "Invalid path");

        if (std.mem.eql(u8, next, "bids")) {
            const auction_id = std.fmt.parseInt(i64, id_str, 10) catch {
                return try jsonError(allocator, "Invalid auction ID");
            };
            const user = try authenticateRequest(allocator, jwt_payload);
            defer user.deinit(allocator);
            return try createBidHandler(allocator, state, auction_id, user, body);
        }
    }

    return try jsonError(allocator, "Not found");
}

fn authenticateRequest(allocator: std.mem.Allocator, jwt_payload: ?[]const u8) !User {
    const payload = jwt_payload orelse return error.Unauthorized;
    return try jwt.decodeJwtUser(allocator, payload);
}

fn formatUser(writer: anytype, user: User) !void {
    switch (user) {
        .buyer_or_seller => |u| {
            try writer.print("BuyerOrSeller|{s}|{s}", .{ u.user_id, u.name });
        },
        .support => |u| {
            try writer.print("Support|{s}", .{u.user_id});
        },
    }
}

fn formatIso8601(writer: anytype, timestamp: i64) !void {
    // Simple ISO 8601 formatting: "YYYY-MM-DDTHH:MM:SSZ"
    // For simplicity, we'll use basic math (not handling leap years perfectly)
    const seconds = @mod(timestamp, 60);
    const minutes = @mod(@divFloor(timestamp, 60), 60);
    const hours = @mod(@divFloor(timestamp, 3600), 24);
    const days_since_epoch = @divFloor(timestamp, 86400);

    const year: i64 = 1970 + @divFloor(days_since_epoch, 365);
    const day_of_year = @mod(days_since_epoch, 365);
    const month: i64 = @min(12, @divFloor(day_of_year, 30) + 1);
    const day: i64 = @mod(day_of_year, 30) + 1;

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year, month, day, hours, minutes, seconds
    });
}

fn parseTimestamp(iso_string: []const u8) !i64 {
    // Parse ISO 8601 format: "2018-01-01T10:00:00.000Z" or "2018-01-01T10:00:00Z"
    // For simplicity, we'll use a basic parser
    // Format: YYYY-MM-DDTHH:MM:SS.sssZ or YYYY-MM-DDTHH:MM:SSZ

    if (iso_string.len < 19) return error.InvalidTimestamp;

    const year = try std.fmt.parseInt(i32, iso_string[0..4], 10);
    const month = try std.fmt.parseInt(u4, iso_string[5..7], 10);
    const day = try std.fmt.parseInt(u5, iso_string[8..10], 10);
    const hour = try std.fmt.parseInt(u5, iso_string[11..13], 10);
    const minute = try std.fmt.parseInt(u6, iso_string[14..16], 10);
    const second = try std.fmt.parseInt(u6, iso_string[17..19], 10);

    // Simple epoch calculation (approximate, ignoring leap years/seconds for simplicity)
    const days_since_epoch = @as(i64, year - 1970) * 365 + @divFloor(@as(i64, year - 1969), 4) +
        @as(i64, month - 1) * 30 + @as(i64, day - 1);

    const seconds = days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return seconds;
}

fn getAuctionsHandler(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    state.mutex.lock();
    defer state.mutex.unlock();

    var list = ArrayList(u8).init(allocator);
    errdefer list.deinit();
    const writer = list.writer();

    try writer.writeAll("[");

    var it = state.repository.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;

        try writer.print(
            \\{{"id":{d},"startsAt":{d},"title":"{s}","expiry":{d},"currency":"{s}"}}
        , .{
            entry.value_ptr.auction.id,
            entry.value_ptr.auction.starts_at,
            entry.value_ptr.auction.title,
            entry.value_ptr.auction.expiry,
            @tagName(entry.value_ptr.auction.currency),
        });
    }

    try writer.writeAll("]");
    return list.toOwnedSlice();
}

fn getAuctionHandler(allocator: std.mem.Allocator, state: *AppState, auction_id: i64) ![]u8 {
    state.mutex.lock();
    defer state.mutex.unlock();

    const entry = state.repository.getPtr(auction_id) orelse {
        return try jsonError(allocator, "Auction not found");
    };

    const bids = domain.getBids(entry.state);
    const winner_info = domain.getWinnerAndPrice(entry.state);

    var list = ArrayList(u8).init(allocator);
    errdefer list.deinit();
    const writer = list.writer();

    try writer.print(
        \\{{"id":{d},"startsAt":{d},"title":"{s}","expiry":{d},"currency":"{s}","bids":[
    , .{
        entry.auction.id,
        entry.auction.starts_at,
        entry.auction.title,
        entry.auction.expiry,
        @tagName(entry.auction.currency),
    });

    for (bids, 0..) |bid, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("{\"amount\":");
        try writer.print("{d}", .{bid.amount});
        try writer.writeAll(",\"bidder\":\"");
        try formatUser(writer, bid.bidder);
        try writer.writeAll("\"}");
    }

    try writer.writeAll("]");

    if (winner_info) |info| {
        try writer.print(
            \\,"winner":"{s}","winnerPrice":{d}
        , .{ info.winner, info.amount });
    } else {
        try writer.writeAll(",\"winner\":null,\"winnerPrice\":null");
    }

    try writer.writeAll("}");
    return list.toOwnedSlice();
}

fn createAuctionHandler(allocator: std.mem.Allocator, state: *AppState, user: User, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try jsonError(allocator, "Invalid JSON");
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const id = if (obj.get("id")) |v| blk: {
        break :blk switch (v) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return try jsonError(allocator, "Invalid id type"),
        };
    } else return try jsonError(allocator, "Missing id");
    const starts_at = if (obj.get("startsAt")) |v| try parseTimestamp(v.string) else return try jsonError(allocator, "Missing startsAt");
    const ends_at = if (obj.get("endsAt")) |v| try parseTimestamp(v.string) else return try jsonError(allocator, "Missing endsAt");
    const title = if (obj.get("title")) |v| v.string else return try jsonError(allocator, "Missing title");
    const currency_str = if (obj.get("currency")) |v| v.string else return try jsonError(allocator, "Missing currency");

    const currency = std.meta.stringToEnum(models.Currency, currency_str) orelse return try jsonError(allocator, "Invalid currency");

    const typ = models.AuctionType{
        .timed_ascending = .{
            .reserve_price = 0,
            .min_raise = 0,
            .time_frame_seconds = 0,
        },
    };

    const auction = Auction{
        .id = id,
        .starts_at = starts_at,
        .title = try allocator.dupe(u8, title),
        .expiry = ends_at,
        .seller = try duplicateUser(allocator, user),
        .typ = typ,
        .currency = currency,
    };
    errdefer auction.deinit(allocator);

    const now = std.time.timestamp();
    const command = Command{
        .add_auction = .{
            .at = now,
            .auction = auction,
        },
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const result = try domain.handle(allocator, command, &state.repository);

    switch (result) {
        .success => |event| {
            const events_slice = [_]Event{event};
            try persistence.writeEvents(allocator, state.events_file, &events_slice);

            var response = ArrayList(u8).init(allocator);
            errdefer response.deinit();
            const writer = response.writer();

            try writer.print(
                \\{{"$type":"AuctionAdded","at":"
            , .{});
            try formatIso8601(writer, now);
            try writer.print(
                \\","auction":{{"id":{d},"startsAt":"
            , .{id});
            try formatIso8601(writer, starts_at);
            try writer.print(
                \\","title":"{s}","expiry":"
            , .{title});
            try formatIso8601(writer, ends_at);
            try writer.print(
                \\","user":"{s}","type":"English|0|0|0","currency":"{s}"}}}}
            , .{ user.userId(), @tagName(currency) });

            return response.toOwnedSlice();
        },
        .failure => |err| {
            if (err == error.AuctionAlreadyExists) {
                return error.AuctionAlreadyExists;
            }
            return try jsonError(allocator, @errorName(err));
        },
    }
}

fn createBidHandler(
    allocator: std.mem.Allocator,
    state: *AppState,
    auction_id: i64,
    user: User,
    body: []const u8,
) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try jsonError(allocator, "Invalid JSON");
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const amount = if (obj.get("amount")) |v| blk: {
        break :blk switch (v) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return try jsonError(allocator, "Invalid amount type"),
        };
    } else return try jsonError(allocator, "Missing amount");

    const now = std.time.timestamp();
    const bid = Bid{
        .auction_id = auction_id,
        .bidder = try duplicateUser(allocator, user),
        .at = now,
        .amount = amount,
    };
    errdefer bid.deinit(allocator);

    const command = Command{
        .place_bid = .{
            .at = now,
            .bid = bid,
        },
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const result = try domain.handle(allocator, command, &state.repository);

    switch (result) {
        .success => |event| {
            const events_slice = [_]Event{event};
            try persistence.writeEvents(allocator, state.events_file, &events_slice);

            var response = ArrayList(u8).init(allocator);
            errdefer response.deinit();
            const writer = response.writer();

            try writer.print(
                \\{{"$type":"BidAccepted","at":"
            , .{});
            try formatIso8601(writer, now);
            try writer.print(
                \\","bid":{{"auction":{d},"user":"{s}","amount":{d},"at":"
            , .{ auction_id, user.userId(), amount });
            try formatIso8601(writer, now);
            try writer.writeAll("\"}}");

            return response.toOwnedSlice();
        },
        .failure => |err| {
            if (err == error.UnknownAuction) {
                return error.UnknownAuction;
            }
            return try jsonError(allocator, @errorName(err));
        },
    }
}

fn duplicateUser(allocator: std.mem.Allocator, user: User) !User {
    switch (user) {
        .buyer_or_seller => |u| {
            return User{
                .buyer_or_seller = .{
                    .user_id = try allocator.dupe(u8, u.user_id),
                    .name = try allocator.dupe(u8, u.name),
                },
            };
        },
        .support => |u| {
            return User{
                .support = .{
                    .user_id = try allocator.dupe(u8, u.user_id),
                },
            };
        },
    }
}

fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var list = ArrayList(u8).init(allocator);
    errdefer list.deinit();
    const writer = list.writer();
    try writer.print("{{\"message\":\"{s}\"}}", .{message});
    return list.toOwnedSlice();
}
