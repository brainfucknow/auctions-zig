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
    _ = body;

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
        return try createAuctionHandler(allocator, state, user);
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
            return try createBidHandler(allocator, state, auction_id, user);
        }
    }

    return try jsonError(allocator, "Not found");
}

fn authenticateRequest(allocator: std.mem.Allocator, jwt_payload: ?[]const u8) !User {
    const payload = jwt_payload orelse return error.Unauthorized;
    return try jwt.decodeJwtUser(allocator, payload);
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
        try writer.print(
            \\{{"amount":{d},"bidder":"{s}"}}
        , .{ bid.amount, bid.bidder.userId() });
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

fn createAuctionHandler(allocator: std.mem.Allocator, state: *AppState, user: User) ![]u8 {
    // For now, hardcoded auction for testing
    const id: i64 = 1;
    const starts_at = std.time.timestamp();
    const title = "Test Auction";
    const ends_at = starts_at + 86400;
    const currency = models.Currency.VAC;

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
                \\{{"$type":"auction_added","at":{d},"auction":{{"id":{d},"starts_at":{d},"title":"{s}","expiry":{d}}}}}
            , .{ now, id, starts_at, title, ends_at });

            return response.toOwnedSlice();
        },
        .failure => |err| {
            return try jsonError(allocator, @errorName(err));
        },
    }
}

fn createBidHandler(
    allocator: std.mem.Allocator,
    state: *AppState,
    auction_id: i64,
    user: User,
) ![]u8 {
    // For now, hardcoded bid amount for testing
    const amount: i64 = 100;

    const now = std.time.timestamp();
    const bid = Bid{
        .auction_id = auction_id,
        .bidder = try duplicateUser(allocator, user),
        .at = now,
        .amount = amount,
    };

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
                \\{{"$type":"bid_accepted","at":{d},"bid":{{"auction_id":{d},"amount":{d}}}}}
            , .{ now, auction_id, amount });

            return response.toOwnedSlice();
        },
        .failure => |err| {
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
