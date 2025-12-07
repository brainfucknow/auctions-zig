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
    _ = allocator;
    _ = file_path;
    _ = events;
    // Persistence disabled for now
}

fn serializeEvent(allocator: std.mem.Allocator, event: Event) ![]u8 {
    _ = event;
    _ = allocator;
    // Simplified for now - JSON serialization API changed in Zig 0.15
    return error.NotImplemented;
}

pub fn readEvents(allocator: std.mem.Allocator, file_path: []const u8) ![]Event {
    _ = allocator;
    _ = file_path;
    // Persistence disabled for now
    return &[_]Event{};
}

fn parseEvent(allocator: std.mem.Allocator, value: json.Value) !Event {
    const obj = value.object;
    const typ = obj.get("$type") orelse return error.MissingType;
    const typ_str = typ.string;
    const at_value = obj.get("at") orelse return error.MissingAt;
    const at = @as(i64, @intFromFloat(at_value.float));

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
    const id = @as(i64, @intFromFloat(obj.get("id").?.float));
    const starts_at = @as(i64, @intFromFloat(obj.get("starts_at").?.float));
    const title = obj.get("title").?.string;
    const expiry = @as(i64, @intFromFloat(obj.get("expiry").?.float));
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
    const auction_id = @as(i64, @intFromFloat(obj.get("auction_id").?.float));
    const bidder = try parseUser(allocator, obj.get("bidder").?);
    const at = @as(i64, @intFromFloat(obj.get("at").?.float));
    const amount = @as(i64, @intFromFloat(obj.get("amount").?.float));

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

pub fn eventsToRepository(allocator: std.mem.Allocator, events: []const Event) !domain.Repository {
    var repository = domain.Repository.init(allocator);
    errdefer repository.deinit();

    for (events) |event| {
        switch (event) {
            .auction_added => |e| {
                const empty_state = AuctionState.initEmpty(allocator, e.auction);
                try repository.put(e.auction.id, .{
                    .auction = e.auction,
                    .state = empty_state,
                });
            },
            .bid_accepted => |e| {
                var entry = repository.getPtr(e.bid.auction_id) orelse continue;
                try domain.addBidToState(allocator, e.bid, &entry.state);
            },
        }
    }

    return repository;
}
