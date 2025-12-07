const std = @import("std");
const models = @import("models.zig");
const domain = @import("domain.zig");
const json = std.json;
const ArrayList = std.array_list.Managed;

const Event = models.Event;
const Auction = models.Auction;
const Bid = models.Bid;
const AuctionState = models.AuctionState;

pub const EventJson = struct {
    @"$type": []const u8,
    at: i64,
    auction: ?json.Value = null,
    bid: ?json.Value = null,
};

pub fn writeEvents(allocator: std.mem.Allocator, file_path: []const u8, events: []const Event) !void {
    // Ensure directory exists
    if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |last_slash| {
        const dir_path = file_path[0..last_slash];
        std.fs.cwd().makePath(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    // Open file for appending (create if doesn't exist)
    const file = std.fs.cwd().openFile(file_path, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            const new_file = try std.fs.cwd().createFile(file_path, .{});
            defer new_file.close();

            for (events) |event| {
                const json_line = try serializeEvent(allocator, event);
                defer allocator.free(json_line);
                try new_file.writeAll(json_line);
                try new_file.writeAll("\n");
            }
            return;
        }
        return err;
    };
    defer file.close();

    // Seek to end of file to append
    try file.seekFromEnd(0);

    for (events) |event| {
        const json_line = try serializeEvent(allocator, event);
        defer allocator.free(json_line);
        try file.writeAll(json_line);
        try file.writeAll("\n");
    }
}

fn serializeEvent(allocator: std.mem.Allocator, event: Event) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var jws: json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    switch (event) {
        .auction_added => |e| {
            try jws.beginObject();
            try jws.objectField("$type");
            try jws.write("auction_added");
            try jws.objectField("at");
            try jws.write(e.at);
            try jws.objectField("auction");
            try e.auction.jsonStringify(&jws);
            try jws.endObject();
        },
        .bid_accepted => |e| {
            try jws.beginObject();
            try jws.objectField("$type");
            try jws.write("bid_accepted");
            try jws.objectField("at");
            try jws.write(e.at);
            try jws.objectField("bid");
            try e.bid.jsonStringify(&jws);
            try jws.endObject();
        },
    }

    var array_list = out.toArrayList();
    return try array_list.toOwnedSlice(allocator);
}

pub fn readEvents(allocator: std.mem.Allocator, file_path: []const u8) ![]Event {
    // Check if file exists
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            // If file doesn't exist, return empty slice
            return &[_]Event{};
        }
        return err;
    };
    defer file.close();

    const file_content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max

    var events = ArrayList(Event).init(allocator);
    errdefer {
        for (events.items) |event| {
            event.deinit(allocator);
        }
        events.deinit();
    }

    var parsed_values = ArrayList(json.Parsed(json.Value)).init(allocator);

    var line_it = std.mem.splitScalar(u8, file_content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const parsed = try json.parseFromSlice(json.Value, allocator, trimmed, .{
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        try parsed_values.append(parsed);

        const event = try parseEvent(allocator, parsed.value);
        try events.append(event);
    }

    // Now we can free file_content since we've duplicated all strings
    allocator.free(file_content);

    // Clean up parsed values
    for (parsed_values.items) |parsed| {
        parsed.deinit();
    }
    parsed_values.deinit();

    return events.toOwnedSlice();
}

fn parseEvent(allocator: std.mem.Allocator, value: json.Value) !Event {
    const obj = value.object;
    const typ = obj.get("$type") orelse return error.MissingType;
    const typ_str = typ.string;
    const at_value = obj.get("at") orelse return error.MissingAt;
    const at = switch (at_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidAt,
    };

    if (std.mem.eql(u8, typ_str, "auction_added")) {
        const auction_value = obj.get("auction") orelse return error.MissingAuction;
        const auction = try parseAuction(allocator, auction_value);
        return Event{
            .auction_added = .{
                .at = at,
                .auction = auction,
            },
        };
    } else if (std.mem.eql(u8, typ_str, "bid_accepted")) {
        const bid_value = obj.get("bid") orelse return error.MissingBid;
        const bid = try parseBid(allocator, bid_value);
        return Event{
            .bid_accepted = .{
                .at = at,
                .bid = bid,
            },
        };
    }

    return error.UnknownEventType;
}

fn parseAuction(allocator: std.mem.Allocator, value: json.Value) !Auction {
    const obj = value.object;
    const id_value = obj.get("id").?;
    const id = switch (id_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidId,
    };
    const starts_at_value = obj.get("starts_at").?;
    const starts_at = switch (starts_at_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidStartsAt,
    };
    const title = obj.get("title").?.string;
    const expiry_value = obj.get("expiry").?;
    const expiry = switch (expiry_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidExpiry,
    };
    const seller = try parseUser(allocator, obj.get("seller").?);
    const typ = try parseAuctionType(obj.get("typ").?);
    const currency = try parseCurrency(obj.get("currency").?.string);

    return Auction{
        .id = id,
        .starts_at = starts_at,
        .title = try allocator.dupe(u8, title),
        .expiry = expiry,
        .seller = seller,
        .typ = typ,
        .currency = currency,
    };
}

fn parseBid(allocator: std.mem.Allocator, value: json.Value) !Bid {
    const obj = value.object;
    const auction_id_value = obj.get("auction_id").?;
    const auction_id = switch (auction_id_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidAuctionId,
    };
    const bidder = try parseUser(allocator, obj.get("bidder").?);
    const at_value = obj.get("at").?;
    const at = switch (at_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidAt,
    };
    const amount_value = obj.get("amount").?;
    const amount = switch (amount_value) {
        .integer => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidAmount,
    };

    return Bid{
        .auction_id = auction_id,
        .bidder = bidder,
        .at = at,
        .amount = amount,
    };
}

fn parseUser(allocator: std.mem.Allocator, value: json.Value) !models.User {
    const str = value.string;
    var it = std.mem.splitScalar(u8, str, '|');

    const typ = it.next() orelse return error.InvalidUser;

    if (std.mem.eql(u8, typ, "BuyerOrSeller")) {
        const user_id = it.next() orelse return error.InvalidUser;
        const name = it.next() orelse return error.InvalidUser;
        return models.User{
            .buyer_or_seller = .{
                .user_id = try allocator.dupe(u8, user_id),
                .name = try allocator.dupe(u8, name),
            },
        };
    } else if (std.mem.eql(u8, typ, "Support")) {
        const user_id = it.next() orelse return error.InvalidUser;
        return models.User{
            .support = .{
                .user_id = try allocator.dupe(u8, user_id),
            },
        };
    }
    return error.InvalidUser;
}

fn parseAuctionType(value: json.Value) !models.AuctionType {
    const str = value.string;
    var it = std.mem.splitScalar(u8, str, '|');

    const typ = it.next() orelse return error.InvalidAuctionType;
    if (!std.mem.eql(u8, typ, "English")) return error.InvalidAuctionType;

    const reserve_str = it.next() orelse return error.InvalidAuctionType;
    const min_raise_str = it.next() orelse return error.InvalidAuctionType;
    const time_frame_str = it.next() orelse return error.InvalidAuctionType;

    return models.AuctionType{
        .timed_ascending = .{
            .reserve_price = try std.fmt.parseInt(i64, reserve_str, 10),
            .min_raise = try std.fmt.parseInt(i64, min_raise_str, 10),
            .time_frame_seconds = try std.fmt.parseInt(i64, time_frame_str, 10),
        },
    };
}

fn parseCurrency(str: []const u8) !models.Currency {
    return std.meta.stringToEnum(models.Currency, str) orelse error.InvalidCurrency;
}

fn duplicateAuction(allocator: std.mem.Allocator, auction: Auction) !Auction {
    return Auction{
        .id = auction.id,
        .starts_at = auction.starts_at,
        .title = try allocator.dupe(u8, auction.title),
        .expiry = auction.expiry,
        .seller = try duplicateUser(allocator, auction.seller),
        .typ = auction.typ,
        .currency = auction.currency,
    };
}

fn duplicateUser(allocator: std.mem.Allocator, user: models.User) !models.User {
    return switch (user) {
        .buyer_or_seller => |u| models.User{
            .buyer_or_seller = .{
                .user_id = try allocator.dupe(u8, u.user_id),
                .name = try allocator.dupe(u8, u.name),
            },
        },
        .support => |u| models.User{
            .support = .{
                .user_id = try allocator.dupe(u8, u.user_id),
            },
        },
    };
}

fn duplicateBid(allocator: std.mem.Allocator, bid: Bid) !Bid {
    return Bid{
        .auction_id = bid.auction_id,
        .bidder = try duplicateUser(allocator, bid.bidder),
        .at = bid.at,
        .amount = bid.amount,
    };
}

pub fn eventsToRepository(allocator: std.mem.Allocator, events: []const Event) !domain.Repository {
    var repository = domain.Repository.init(allocator);
    errdefer repository.deinit();

    for (events) |event| {
        switch (event) {
            .auction_added => |e| {
                const auction_copy = try duplicateAuction(allocator, e.auction);
                const empty_state = AuctionState.initEmpty(allocator, auction_copy);
                try repository.put(auction_copy.id, .{
                    .auction = auction_copy,
                    .state = empty_state,
                });
            },
            .bid_accepted => |e| {
                var entry = repository.getPtr(e.bid.auction_id) orelse continue;
                const bid_copy = try duplicateBid(allocator, e.bid);
                try domain.addBidToState(allocator, bid_copy, &entry.state);
            },
        }
    }

    return repository;
}
