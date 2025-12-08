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

// Response structs for JSON serialization
const AuctionListItem = struct {
    id: i64,
    startsAt: []const u8,
    title: []const u8,
    expiry: []const u8,
    currency: models.Currency,
};

const BidResponse = struct {
    amount: i64,
    bidder: []const u8,
};

const AuctionDetailResponse = struct {
    id: i64,
    startsAt: []const u8,
    title: []const u8,
    expiry: []const u8,
    currency: models.Currency,
    bids: []BidResponse,
    winner: ?[]const u8,
    winnerPrice: ?i64,
};

const ErrorResponse = struct {
    message: []const u8,
};

const AuctionAddedAuctionResponse = struct {
    id: i64,
    startsAt: []const u8,
    title: []const u8,
    expiry: []const u8,
    user: []const u8,
    type: []const u8,
    currency: []const u8,
};

const AuctionAddedResponse = struct {
    @"$type": []const u8 = "AuctionAdded",
    at: []const u8,
    auction: AuctionAddedAuctionResponse,
};

const BidAcceptedBidResponse = struct {
    auction: i64,
    user: []const u8,
    amount: i64,
    at: []const u8,
};

const BidAcceptedResponse = struct {
    @"$type": []const u8 = "BidAccepted",
    at: []const u8,
    bid: BidAcceptedBidResponse,
};

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
    // ISO 8601 formatting: "YYYY-MM-DDTHH:MM:SSZ"
    const seconds = @mod(timestamp, 60);
    const minutes = @mod(@divFloor(timestamp, 60), 60);
    const hours = @mod(@divFloor(timestamp, 3600), 24);
    var days_since_epoch = @divFloor(timestamp, 86400);

    // Calculate year accounting for leap years
    var year: i64 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days_since_epoch < days_in_year) break;
        days_since_epoch -= days_in_year;
        year += 1;
    }

    // Calculate month and day
    const month_lengths = if (isLeapYear(year))
        [_]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: i64 = 1;
    for (month_lengths) |days_in_month| {
        if (days_since_epoch < days_in_month) break;
        days_since_epoch -= days_in_month;
        month += 1;
    }
    const day = days_since_epoch + 1;

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(year)),
        @as(u8, @intCast(month)),
        @as(u8, @intCast(day)),
        @as(u8, @intCast(hours)),
        @as(u8, @intCast(minutes)),
        @as(u8, @intCast(seconds)),
    });
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or (@mod(year, 400) == 0);
}

fn formatIso8601Alloc(allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
    var buffer = ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    try formatIso8601(buffer.writer(), timestamp);
    return buffer.toOwnedSlice();
}

fn jsonStringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var jws: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    try jws.write(value);

    var array_list = out.toArrayList();
    return try array_list.toOwnedSlice(allocator);
}

fn parseTimestamp(iso_string: []const u8) !i64 {
    // Parse ISO 8601 format: "2018-01-01T10:00:00.000Z" or "2018-01-01T10:00:00Z"
    // Format: YYYY-MM-DDTHH:MM:SS.sssZ or YYYY-MM-DDTHH:MM:SSZ

    if (iso_string.len < 19) return error.InvalidTimestamp;

    const year = try std.fmt.parseInt(i32, iso_string[0..4], 10);
    const month = try std.fmt.parseInt(u8, iso_string[5..7], 10);
    const day = try std.fmt.parseInt(u8, iso_string[8..10], 10);
    const hour = try std.fmt.parseInt(u8, iso_string[11..13], 10);
    const minute = try std.fmt.parseInt(u8, iso_string[14..16], 10);
    const second = try std.fmt.parseInt(u8, iso_string[17..19], 10);

    // Proper epoch calculation accounting for leap years and actual month lengths
    var days_since_epoch: i64 = 0;

    // Count days in complete years from 1970 to year-1
    var y: i32 = 1970;
    while (y < year) : (y += 1) {
        days_since_epoch += if (isLeapYear(y)) 366 else 365;
    }

    // Count days in complete months of the target year
    const month_lengths = if (isLeapYear(year))
        [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days_since_epoch += month_lengths[m - 1];
    }

    // Add remaining days (day is 1-indexed, so subtract 1)
    days_since_epoch += @as(i64, day - 1);

    const seconds = days_since_epoch * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return seconds;
}

fn getAuctionsHandler(allocator: std.mem.Allocator, state: *AppState) ![]u8 {
    state.mutex.lock();
    defer state.mutex.unlock();

    var auctions = ArrayList(AuctionListItem).init(allocator);
    defer auctions.deinit();
    defer {
        for (auctions.items) |item| {
            allocator.free(item.startsAt);
            allocator.free(item.expiry);
        }
    }

    var it = state.repository.iterator();
    while (it.next()) |entry| {
        const starts_at_iso = try formatIso8601Alloc(allocator, entry.value_ptr.auction.starts_at);
        const expiry_iso = try formatIso8601Alloc(allocator, entry.value_ptr.auction.expiry);

        try auctions.append(.{
            .id = entry.value_ptr.auction.id,
            .startsAt = starts_at_iso,
            .title = entry.value_ptr.auction.title,
            .expiry = expiry_iso,
            .currency = entry.value_ptr.auction.currency,
        });
    }

    return jsonStringifyAlloc(allocator, auctions.items);
}

fn getAuctionHandler(allocator: std.mem.Allocator, state: *AppState, auction_id: i64) ![]u8 {
    state.mutex.lock();
    defer state.mutex.unlock();

    const entry = state.repository.getPtr(auction_id) orelse {
        return try jsonError(allocator, "Auction not found");
    };

    const bids = domain.getBids(entry.state);
    const winner_info = domain.getWinnerAndPrice(entry.state);

    // Build bids array with formatted bidder strings
    var bid_responses = ArrayList(BidResponse).init(allocator);
    defer bid_responses.deinit();

    for (bids) |bid| {
        var bidder_buffer = ArrayList(u8).init(allocator);
        defer bidder_buffer.deinit();
        try formatUser(bidder_buffer.writer(), bid.bidder);

        try bid_responses.append(.{
            .amount = bid.amount,
            .bidder = try bidder_buffer.toOwnedSlice(),
        });
    }
    defer {
        for (bid_responses.items) |bid_resp| {
            allocator.free(bid_resp.bidder);
        }
    }

    const starts_at_iso = try formatIso8601Alloc(allocator, entry.auction.starts_at);
    defer allocator.free(starts_at_iso);
    const expiry_iso = try formatIso8601Alloc(allocator, entry.auction.expiry);
    defer allocator.free(expiry_iso);

    const response = AuctionDetailResponse{
        .id = entry.auction.id,
        .startsAt = starts_at_iso,
        .title = entry.auction.title,
        .expiry = expiry_iso,
        .currency = entry.auction.currency,
        .bids = bid_responses.items,
        .winner = if (winner_info) |info| info.winner else null,
        .winnerPrice = if (winner_info) |info| info.amount else null,
    };

    return jsonStringifyAlloc(allocator, response);
}

fn createAuctionHandler(allocator: std.mem.Allocator, state: *AppState, user: User, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return try jsonError(allocator, "Invalid JSON");
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

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

    // Lock mutex to generate ID and add auction atomically
    state.mutex.lock();
    defer state.mutex.unlock();

    // Auto-generate ID if not provided
    const id = if (obj.get("id")) |v| blk: {
        break :blk switch (v) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => return try jsonError(allocator, "Invalid id type"),
        };
    } else blk: {
        // Find the maximum ID in the repository and add 1
        var max_id: i64 = 0;
        var it = state.repository.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* > max_id) {
                max_id = entry.key_ptr.*;
            }
        }
        break :blk max_id + 1;
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

    const result = try domain.handle(allocator, command, &state.repository);

    switch (result) {
        .success => |event| {
            const events_slice = [_]Event{event};
            try persistence.writeEvents(allocator, state.events_file, &events_slice);

            const at_iso = try formatIso8601Alloc(allocator, now);
            defer allocator.free(at_iso);
            const starts_at_iso = try formatIso8601Alloc(allocator, starts_at);
            defer allocator.free(starts_at_iso);
            const expiry_iso = try formatIso8601Alloc(allocator, ends_at);
            defer allocator.free(expiry_iso);

            const user_id = try allocator.dupe(u8, user.userId());
            defer allocator.free(user_id);
            const currency_tag = try allocator.dupe(u8, @tagName(currency));
            defer allocator.free(currency_tag);
            const title_dup = try allocator.dupe(u8, title);
            defer allocator.free(title_dup);

            const response = AuctionAddedResponse{
                .at = at_iso,
                .auction = .{
                    .id = id,
                    .startsAt = starts_at_iso,
                    .title = title_dup,
                    .expiry = expiry_iso,
                    .user = user_id,
                    .type = "English|0|0|0",
                    .currency = currency_tag,
                },
            };

            return jsonStringifyAlloc(allocator, response);
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

            const at_iso = try formatIso8601Alloc(allocator, now);
            defer allocator.free(at_iso);
            const bid_at_iso = try formatIso8601Alloc(allocator, now);
            defer allocator.free(bid_at_iso);
            const user_id = try allocator.dupe(u8, user.userId());
            defer allocator.free(user_id);

            const response = BidAcceptedResponse{
                .at = at_iso,
                .bid = .{
                    .auction = auction_id,
                    .user = user_id,
                    .amount = amount,
                    .at = bid_at_iso,
                },
            };

            return jsonStringifyAlloc(allocator, response);
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
    const response = ErrorResponse{ .message = message };
    return jsonStringifyAlloc(allocator, response);
}

// ============================================================================
// Tests
// ============================================================================

test "parseTimestamp - regular date" {
    const timestamp = try parseTimestamp("2025-12-08T17:00:00Z");
    // Expected: December 8, 2025, 17:00:00
    try std.testing.expectEqual(@as(i64, 1765213200), timestamp);
}

test "parseTimestamp - January 1st" {
    const timestamp = try parseTimestamp("2025-01-01T00:00:00Z");
    // Expected: January 1, 2025, 00:00:00
    // Days from 1970-01-01 to 2025-01-01: 20089 days
    try std.testing.expectEqual(@as(i64, 1735689600), timestamp);
}

test "parseTimestamp - December 31st" {
    const timestamp = try parseTimestamp("2025-12-31T23:59:59Z");
    // Expected: December 31, 2025, 23:59:59
    // Days from 1970-01-01 to 2025-12-31: 20453 days
    // Plus 23:59:59 = 86399 seconds
    try std.testing.expectEqual(@as(i64, 1767225599), timestamp);
}

test "parseTimestamp - leap year February 29" {
    const timestamp = try parseTimestamp("2024-02-29T12:00:00Z");
    // Expected: February 29, 2024 (leap year), 12:00:00
    // Days from 1970-01-01 to 2024-02-29: 19781 days
    // Plus 12 hours = 43200 seconds
    try std.testing.expectEqual(@as(i64, 1709208000), timestamp);
}

test "parseTimestamp - epoch" {
    const timestamp = try parseTimestamp("1970-01-01T00:00:00Z");
    try std.testing.expectEqual(@as(i64, 0), timestamp);
}

test "parseTimestamp - different months" {
    // Test that different month lengths are handled correctly
    const jan31 = try parseTimestamp("2025-01-31T00:00:00Z");
    const feb1 = try parseTimestamp("2025-02-01T00:00:00Z");

    // Feb 1 should be exactly 1 day after Jan 31
    try std.testing.expectEqual(jan31 + 86400, feb1);
}

test "formatIso8601 - regular timestamp" {
    const allocator = std.testing.allocator;

    // December 8, 2025, 17:00:00
    const result = try formatIso8601Alloc(allocator, 1765213200);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("2025-12-08T17:00:00Z", result);
}

test "formatIso8601 - January 1st" {
    const allocator = std.testing.allocator;

    // January 1, 2025, 00:00:00
    const result = try formatIso8601Alloc(allocator, 1735689600);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("2025-01-01T00:00:00Z", result);
}

test "formatIso8601 - December 31st" {
    const allocator = std.testing.allocator;

    // December 31, 2025, 23:59:59
    const result = try formatIso8601Alloc(allocator, 1767225599);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("2025-12-31T23:59:59Z", result);
}

test "formatIso8601 - leap year February 29" {
    const allocator = std.testing.allocator;

    // February 29, 2024, 12:00:00
    const result = try formatIso8601Alloc(allocator, 1709208000);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("2024-02-29T12:00:00Z", result);
}

test "formatIso8601 - epoch" {
    const allocator = std.testing.allocator;

    const result = try formatIso8601Alloc(allocator, 0);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", result);
}

test "formatIso8601 - non-leap year February 28" {
    const allocator = std.testing.allocator;

    // February 28, 2025, 00:00:00
    const result = try formatIso8601Alloc(allocator, 1740700800);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("2025-02-28T00:00:00Z", result);
}

test "round-trip - parse then format" {
    const allocator = std.testing.allocator;

    const test_cases = [_][]const u8{
        "2025-12-08T17:00:00Z",
        "2024-02-29T12:00:00Z", // Leap year
        "2025-01-01T00:00:00Z",
        "2025-12-31T23:59:59Z",
        "1970-01-01T00:00:00Z", // Epoch
        "2025-07-15T14:30:45Z",
    };

    for (test_cases) |test_case| {
        const timestamp = try parseTimestamp(test_case);
        const formatted = try formatIso8601Alloc(allocator, timestamp);
        defer allocator.free(formatted);

        try std.testing.expectEqualStrings(test_case, formatted);
    }
}

test "round-trip - format then parse" {
    const allocator = std.testing.allocator;

    const test_timestamps = [_]i64{
        1765213200, // 2025-12-08 17:00:00
        1709208000, // 2024-02-29 12:00:00 (leap year)
        1735689600, // 2025-01-01 00:00:00
        1767225599, // 2025-12-31 23:59:59
        0,          // 1970-01-01 00:00:00 (epoch)
        1752589845, // 2025-07-15 14:30:45
    };

    for (test_timestamps) |test_timestamp| {
        const formatted = try formatIso8601Alloc(allocator, test_timestamp);
        defer allocator.free(formatted);

        const parsed = try parseTimestamp(formatted);

        try std.testing.expectEqual(test_timestamp, parsed);
    }
}

test "isLeapYear - standard cases" {
    // Divisible by 4 but not 100: leap year
    try std.testing.expect(isLeapYear(2024));
    try std.testing.expect(isLeapYear(2020));

    // Not divisible by 4: not leap year
    try std.testing.expect(!isLeapYear(2023));
    try std.testing.expect(!isLeapYear(2025));

    // Divisible by 100 but not 400: not leap year
    try std.testing.expect(!isLeapYear(1900));
    try std.testing.expect(!isLeapYear(2100));

    // Divisible by 400: leap year
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(isLeapYear(2400));
}
