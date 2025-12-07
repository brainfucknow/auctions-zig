const std = @import("std");
const json = std.json;
const ArrayList = std.array_list.Managed;

pub const UserId = []const u8;
pub const AuctionId = i64;

pub const Currency = enum {
    VAC, // Virtual Auction Currency
    SEK, // Swedish Krona
    DKK, // Danish Krone

    pub fn jsonStringify(self: Currency, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !Currency {
        _ = options;
        const str = try source.nextAlloc(allocator, .alloc_always);
        defer allocator.free(str);
        return std.meta.stringToEnum(Currency, str) orelse error.InvalidCurrency;
    }
};

pub const User = union(enum) {
    buyer_or_seller: struct {
        user_id: []const u8,
        name: []const u8,
    },
    support: struct {
        user_id: []const u8,
    },

    pub fn userId(self: User) []const u8 {
        return switch (self) {
            .buyer_or_seller => |u| u.user_id,
            .support => |u| u.user_id,
        };
    }

    pub fn jsonStringify(self: User, jw: anytype) !void {
        switch (self) {
            .buyer_or_seller => |u| {
                var buffer: [1024]u8 = undefined;
                const str = try std.fmt.bufPrint(&buffer, "BuyerOrSeller|{s}|{s}", .{ u.user_id, u.name });
                try jw.write(str);
            },
            .support => |u| {
                var buffer: [512]u8 = undefined;
                const str = try std.fmt.bufPrint(&buffer, "Support|{s}", .{u.user_id});
                try jw.write(str);
            },
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !User {
        _ = options;
        const str = try source.nextAlloc(allocator, .alloc_always);
        var it = std.mem.splitScalar(u8, str, '|');

        const typ = it.next() orelse return error.InvalidUser;

        if (std.mem.eql(u8, typ, "BuyerOrSeller")) {
            const user_id = it.next() orelse return error.InvalidUser;
            const name = it.next() orelse return error.InvalidUser;
            return User{
                .buyer_or_seller = .{
                    .user_id = try allocator.dupe(u8, user_id),
                    .name = try allocator.dupe(u8, name),
                },
            };
        } else if (std.mem.eql(u8, typ, "Support")) {
            const user_id = it.next() orelse return error.InvalidUser;
            return User{
                .support = .{
                    .user_id = try allocator.dupe(u8, user_id),
                },
            };
        }
        return error.InvalidUser;
    }

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        switch (self) {
            .buyer_or_seller => |u| {
                allocator.free(u.user_id);
                allocator.free(u.name);
            },
            .support => |u| {
                allocator.free(u.user_id);
            },
        }
    }
};

pub const AuctionError = error{
    UnknownAuction,
    AuctionAlreadyExists,
    AuctionHasEnded,
    AuctionHasNotStarted,
    SellerCannotPlaceBids,
    InvalidUserData,
    MustPlaceBidOverHighestBid,
    AlreadyPlacedBid,
    OutOfMemory,
};

pub const AuctionTypeOptions = struct {
    reserve_price: i64 = 0,
    min_raise: i64 = 0,
    time_frame_seconds: i64 = 0,

    pub fn jsonStringify(self: AuctionTypeOptions, jw: anytype) !void {
        var buffer: [256]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "English|{d}|{d}|{d}", .{ self.reserve_price, self.min_raise, self.time_frame_seconds });
        try jw.write(str);
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !AuctionTypeOptions {
        _ = options;
        const str = try source.nextAlloc(allocator, .alloc_always);
        defer allocator.free(str);

        var it = std.mem.splitScalar(u8, str, '|');
        const typ = it.next() orelse return error.InvalidAuctionType;
        if (!std.mem.eql(u8, typ, "English")) return error.InvalidAuctionType;

        const reserve_str = it.next() orelse return error.InvalidAuctionType;
        const min_raise_str = it.next() orelse return error.InvalidAuctionType;
        const time_frame_str = it.next() orelse return error.InvalidAuctionType;

        return AuctionTypeOptions{
            .reserve_price = try std.fmt.parseInt(i64, reserve_str, 10),
            .min_raise = try std.fmt.parseInt(i64, min_raise_str, 10),
            .time_frame_seconds = try std.fmt.parseInt(i64, time_frame_str, 10),
        };
    }
};

pub const AuctionType = union(enum) {
    timed_ascending: AuctionTypeOptions,

    pub fn jsonStringify(self: AuctionType, jw: anytype) !void {
        switch (self) {
            .timed_ascending => |opts| try opts.jsonStringify(jw),
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: json.ParseOptions) !AuctionType {
        const opts = try AuctionTypeOptions.jsonParse(allocator, source, options);
        return AuctionType{ .timed_ascending = opts };
    }
};

pub const Auction = struct {
    id: AuctionId,
    starts_at: i64,
    title: []const u8,
    expiry: i64,
    seller: User,
    typ: AuctionType,
    currency: Currency,

    pub fn deinit(self: Auction, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        self.seller.deinit(allocator);
    }
};

pub const Bid = struct {
    auction_id: AuctionId,
    bidder: User,
    at: i64,
    amount: i64,

    pub fn deinit(self: Bid, allocator: std.mem.Allocator) void {
        self.bidder.deinit(allocator);
    }
};

pub const AuctionState = union(enum) {
    awaiting_start: struct {
        start_time: i64,
        expiry: i64,
        options: AuctionTypeOptions,
    },
    ongoing: struct {
        bids: ArrayList(Bid),
        expiry: i64,
        options: AuctionTypeOptions,
    },
    has_ended: struct {
        bids: ArrayList(Bid),
        expiry: i64,
        options: AuctionTypeOptions,
    },

    pub fn initEmpty(allocator: std.mem.Allocator, auction: Auction) AuctionState {
        const opts = switch (auction.typ) {
            .timed_ascending => |o| o,
        };
        _ = allocator;
        return AuctionState{
            .awaiting_start = .{
                .start_time = auction.starts_at,
                .expiry = auction.expiry,
                .options = opts,
            },
        };
    }

    pub fn deinit(self: *AuctionState, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .awaiting_start => {},
            .ongoing => |*state| {
                for (state.bids.items) |bid| {
                    bid.deinit(allocator);
                }
                state.bids.deinit();
            },
            .has_ended => |*state| {
                for (state.bids.items) |bid| {
                    bid.deinit(allocator);
                }
                state.bids.deinit();
            },
        }
    }
};

pub const Command = union(enum) {
    add_auction: struct {
        at: i64,
        auction: Auction,
    },
    place_bid: struct {
        at: i64,
        bid: Bid,
    },
};

pub const Event = union(enum) {
    auction_added: struct {
        at: i64,
        auction: Auction,
    },
    bid_accepted: struct {
        at: i64,
        bid: Bid,
    },

    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .auction_added => |e| e.auction.deinit(allocator),
            .bid_accepted => |e| e.bid.deinit(allocator),
        }
    }
};
