const std = @import("std");
const testing = std.testing;
const persistence = @import("persistence.zig");
const models = @import("models.zig");

const Event = models.Event;
const Auction = models.Auction;
const Bid = models.Bid;
const User = models.User;
const Currency = models.Currency;
const AuctionType = models.AuctionType;

// Helper functions to create test data
fn createSampleUser(allocator: std.mem.Allocator, user_id: []const u8, name: []const u8) !User {
    return User{
        .buyer_or_seller = .{
            .user_id = try allocator.dupe(u8, user_id),
            .name = try allocator.dupe(u8, name),
        },
    };
}

fn createSampleAuction(allocator: std.mem.Allocator, id: i64, title: []const u8, seller: User) !Auction {
    return Auction{
        .id = id,
        .starts_at = 1543658400, // 2018-12-01T10:00:00Z
        .title = try allocator.dupe(u8, title),
        .expiry = 1589796000, // 2020-05-18T10:00:00Z
        .seller = seller,
        .typ = .{ .timed_ascending = .{
            .reserve_price = 0,
            .min_raise = 0,
            .time_frame_seconds = 0,
        } },
        .currency = .VAC,
    };
}

fn createSampleBid(allocator: std.mem.Allocator, auction_id: i64, bidder: User, amount: i64, at: i64) !Bid {
    _ = allocator;
    return Bid{
        .auction_id = auction_id,
        .bidder = bidder,
        .at = at,
        .amount = amount,
    };
}

test "read events from jsonl file" {
    const allocator = testing.allocator;
    const file_path = "test/samples/sample-events.jsonl";

    const events = try persistence.readEvents(allocator, file_path);
    defer {
        for (events) |event| {
            event.deinit(allocator);
        }
        allocator.free(events);
    }

    // Verify we read 7 events
    try testing.expectEqual(@as(usize, 7), events.len);

    // Verify first event is auction_added
    try testing.expect(events[0] == .auction_added);
    try testing.expectEqual(@as(i64, 1), events[0].auction_added.auction.id);
    try testing.expectEqualStrings("Some auction", events[0].auction_added.auction.title);
    try testing.expectEqual(@as(i64, 1589702116), events[0].auction_added.at);

    // Verify second event is also auction_added
    try testing.expect(events[1] == .auction_added);
    try testing.expectEqual(@as(i64, 2), events[1].auction_added.auction.id);

    // Verify third event is bid_accepted
    try testing.expect(events[2] == .bid_accepted);
    try testing.expectEqual(@as(i64, 1), events[2].bid_accepted.bid.auction_id);
    try testing.expectEqual(@as(i64, 11), events[2].bid_accepted.bid.amount);
}

test "write and read events round trip" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/test-events.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create test events
    const seller = try createSampleUser(allocator, "seller1", "Alice");
    const auction1 = try createSampleAuction(allocator, 1, "Test Auction 1", seller);
    const auction2_seller = try createSampleUser(allocator, "seller2", "Bob");
    const auction2 = try createSampleAuction(allocator, 2, "Test Auction 2", auction2_seller);

    const events = [_]Event{
        Event{ .auction_added = .{
            .at = 1589702116,
            .auction = auction1,
        } },
        Event{ .auction_added = .{
            .at = 1589702119,
            .auction = auction2,
        } },
    };
    defer {
        for (events) |event| {
            event.deinit(allocator);
        }
    }

    // Write events
    try persistence.writeEvents(allocator, file_path, &events);

    // Read events back
    const read_events = try persistence.readEvents(allocator, file_path);
    defer {
        for (read_events) |event| {
            event.deinit(allocator);
        }
        allocator.free(read_events);
    }

    // Verify
    try testing.expectEqual(@as(usize, 2), read_events.len);
    try testing.expectEqual(@as(i64, 1), read_events[0].auction_added.auction.id);
    try testing.expectEqualStrings("Test Auction 1", read_events[0].auction_added.auction.title);
    try testing.expectEqual(@as(i64, 2), read_events[1].auction_added.auction.id);
    try testing.expectEqualStrings("Test Auction 2", read_events[1].auction_added.auction.title);

    // Clean up test file
    std.fs.cwd().deleteFile(file_path) catch {};
}

test "write events appends to existing file" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/test-append-events.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Clean up any existing test file
    std.fs.cwd().deleteFile(file_path) catch {};

    // Create first batch of events
    const seller1 = try createSampleUser(allocator, "seller1", "Alice");
    const auction1 = try createSampleAuction(allocator, 1, "Auction 1", seller1);
    const events1 = [_]Event{
        Event{ .auction_added = .{
            .at = 1589702116,
            .auction = auction1,
        } },
    };
    defer {
        for (events1) |event| {
            event.deinit(allocator);
        }
    }

    // Write first batch
    try persistence.writeEvents(allocator, file_path, &events1);

    // Create second batch of events
    const seller2 = try createSampleUser(allocator, "seller2", "Bob");
    const auction2 = try createSampleAuction(allocator, 2, "Auction 2", seller2);
    const events2 = [_]Event{
        Event{ .auction_added = .{
            .at = 1589702119,
            .auction = auction2,
        } },
    };
    defer {
        for (events2) |event| {
            event.deinit(allocator);
        }
    }

    // Write second batch (should append)
    try persistence.writeEvents(allocator, file_path, &events2);

    // Read all events back
    const read_events = try persistence.readEvents(allocator, file_path);
    defer {
        for (read_events) |event| {
            event.deinit(allocator);
        }
        allocator.free(read_events);
    }

    // Verify both events are present
    try testing.expectEqual(@as(usize, 2), read_events.len);
    try testing.expectEqual(@as(i64, 1), read_events[0].auction_added.auction.id);
    try testing.expectEqual(@as(i64, 2), read_events[1].auction_added.auction.id);

    // Clean up test file
    std.fs.cwd().deleteFile(file_path) catch {};
}

test "read non-existent file returns empty slice" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/non-existent-file.jsonl";

    const events = try persistence.readEvents(allocator, file_path);
    defer allocator.free(events);

    try testing.expectEqual(@as(usize, 0), events.len);
}

test "serialize and deserialize auction_added event" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/test-auction-added.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Clean up any existing test file
    std.fs.cwd().deleteFile(file_path) catch {};

    // Create auction with special characters in title
    const seller = try createSampleUser(allocator, "seller1", "Alice");
    const auction = Auction{
        .id = 42,
        .starts_at = 1543658400,
        .title = try allocator.dupe(u8, "Auction with \"quotes\" and special chars"),
        .expiry = 1589796000,
        .seller = seller,
        .typ = .{ .timed_ascending = .{
            .reserve_price = 100,
            .min_raise = 10,
            .time_frame_seconds = 3600,
        } },
        .currency = .SEK,
    };

    const event = Event{ .auction_added = .{
        .at = 1589702116,
        .auction = auction,
    } };

    const events = [_]Event{event};
    defer {
        for (events) |e| {
            e.deinit(allocator);
        }
    }

    // Write and read back
    try persistence.writeEvents(allocator, file_path, &events);

    const read_events = try persistence.readEvents(allocator, file_path);
    defer {
        for (read_events) |e| {
            e.deinit(allocator);
        }
        allocator.free(read_events);
    }

    // Verify
    try testing.expectEqual(@as(usize, 1), read_events.len);
    try testing.expect(read_events[0] == .auction_added);
    try testing.expectEqual(@as(i64, 42), read_events[0].auction_added.auction.id);
    try testing.expectEqualStrings("Auction with \"quotes\" and special chars", read_events[0].auction_added.auction.title);
    try testing.expectEqual(Currency.SEK, read_events[0].auction_added.auction.currency);
    try testing.expectEqual(@as(i64, 100), read_events[0].auction_added.auction.typ.timed_ascending.reserve_price);
    try testing.expectEqual(@as(i64, 10), read_events[0].auction_added.auction.typ.timed_ascending.min_raise);
    try testing.expectEqual(@as(i64, 3600), read_events[0].auction_added.auction.typ.timed_ascending.time_frame_seconds);

    // Clean up
    std.fs.cwd().deleteFile(file_path) catch {};
}

test "serialize and deserialize bid_accepted event" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/test-bid-accepted.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Clean up any existing test file
    std.fs.cwd().deleteFile(file_path) catch {};

    // Create bid
    const bidder = try createSampleUser(allocator, "buyer1", "Charlie");
    const bid = Bid{
        .auction_id = 123,
        .bidder = bidder,
        .at = 1589702200,
        .amount = 500,
    };

    const event = Event{ .bid_accepted = .{
        .at = 1589702200,
        .bid = bid,
    } };

    const events = [_]Event{event};
    defer {
        for (events) |e| {
            e.deinit(allocator);
        }
    }

    // Write and read back
    try persistence.writeEvents(allocator, file_path, &events);

    const read_events = try persistence.readEvents(allocator, file_path);
    defer {
        for (read_events) |e| {
            e.deinit(allocator);
        }
        allocator.free(read_events);
    }

    // Verify
    try testing.expectEqual(@as(usize, 1), read_events.len);
    try testing.expect(read_events[0] == .bid_accepted);
    try testing.expectEqual(@as(i64, 123), read_events[0].bid_accepted.bid.auction_id);
    try testing.expectEqual(@as(i64, 500), read_events[0].bid_accepted.bid.amount);
    try testing.expectEqual(@as(i64, 1589702200), read_events[0].bid_accepted.bid.at);

    // Clean up
    std.fs.cwd().deleteFile(file_path) catch {};
}

test "deserialize user types correctly" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/test-user-types.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Clean up any existing test file
    std.fs.cwd().deleteFile(file_path) catch {};

    // Create auction with BuyerOrSeller user
    const buyer_or_seller = try createSampleUser(allocator, "user1", "John Doe");
    const auction1 = try createSampleAuction(allocator, 1, "Auction 1", buyer_or_seller);

    // Create auction with Support user
    const support = User{
        .support = .{
            .user_id = try allocator.dupe(u8, "support1"),
        },
    };
    const auction2 = Auction{
        .id = 2,
        .starts_at = 1543658400,
        .title = try allocator.dupe(u8, "Auction 2"),
        .expiry = 1589796000,
        .seller = support,
        .typ = .{ .timed_ascending = .{
            .reserve_price = 0,
            .min_raise = 0,
            .time_frame_seconds = 0,
        } },
        .currency = .VAC,
    };

    const events = [_]Event{
        Event{ .auction_added = .{
            .at = 1589702116,
            .auction = auction1,
        } },
        Event{ .auction_added = .{
            .at = 1589702119,
            .auction = auction2,
        } },
    };
    defer {
        for (events) |event| {
            event.deinit(allocator);
        }
    }

    // Write and read back
    try persistence.writeEvents(allocator, file_path, &events);

    const read_events = try persistence.readEvents(allocator, file_path);
    defer {
        for (read_events) |event| {
            event.deinit(allocator);
        }
        allocator.free(read_events);
    }

    // Verify
    try testing.expectEqual(@as(usize, 2), read_events.len);

    // Check first user is BuyerOrSeller
    try testing.expect(read_events[0].auction_added.auction.seller == .buyer_or_seller);
    try testing.expectEqualStrings("user1", read_events[0].auction_added.auction.seller.buyer_or_seller.user_id);
    try testing.expectEqualStrings("John Doe", read_events[0].auction_added.auction.seller.buyer_or_seller.name);

    // Check second user is Support
    try testing.expect(read_events[1].auction_added.auction.seller == .support);
    try testing.expectEqualStrings("support1", read_events[1].auction_added.auction.seller.support.user_id);

    // Clean up
    std.fs.cwd().deleteFile(file_path) catch {};
}

test "events to repository conversion" {
    const allocator = testing.allocator;

    // Create test events
    const seller = try createSampleUser(allocator, "seller1", "Alice");
    const auction = try createSampleAuction(allocator, 1, "Test Auction", seller);

    const bidder1 = try createSampleUser(allocator, "buyer1", "Bob");
    const bid1 = try createSampleBid(allocator, 1, bidder1, 100, 1589702200);

    const bidder2 = try createSampleUser(allocator, "buyer2", "Charlie");
    const bid2 = try createSampleBid(allocator, 1, bidder2, 150, 1589702300);

    const events = [_]Event{
        Event{ .auction_added = .{
            .at = 1589702116,
            .auction = auction,
        } },
        Event{ .bid_accepted = .{
            .at = 1589702200,
            .bid = bid1,
        } },
        Event{ .bid_accepted = .{
            .at = 1589702300,
            .bid = bid2,
        } },
    };
    defer {
        for (events) |event| {
            event.deinit(allocator);
        }
    }

    // Convert to repository
    var repository = try persistence.eventsToRepository(allocator, &events);
    defer {
        var it = repository.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.auction.deinit(allocator);
            entry.value_ptr.state.deinit(allocator);
        }
        repository.deinit();
    }

    // Verify auction exists
    const entry = repository.getPtr(1);
    try testing.expect(entry != null);
    try testing.expectEqual(@as(i64, 1), entry.?.auction.id);
    try testing.expectEqualStrings("Test Auction", entry.?.auction.title);

    // Verify state has bids
    try testing.expect(entry.?.state == .ongoing);
    try testing.expectEqual(@as(usize, 2), entry.?.state.ongoing.bids.items.len);
    try testing.expectEqual(@as(i64, 100), entry.?.state.ongoing.bids.items[0].amount);
    try testing.expectEqual(@as(i64, 150), entry.?.state.ongoing.bids.items[1].amount);
}

test "parse different currency types" {
    const allocator = testing.allocator;
    const file_path = "test/tmp/test-currencies.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Clean up any existing test file
    std.fs.cwd().deleteFile(file_path) catch {};

    // Create auctions with different currencies
    const seller1 = try createSampleUser(allocator, "seller1", "Alice");
    var auction1 = try createSampleAuction(allocator, 1, "VAC Auction", seller1);
    auction1.currency = .VAC;

    const seller2 = try createSampleUser(allocator, "seller2", "Bob");
    var auction2 = try createSampleAuction(allocator, 2, "SEK Auction", seller2);
    auction2.currency = .SEK;

    const seller3 = try createSampleUser(allocator, "seller3", "Charlie");
    var auction3 = try createSampleAuction(allocator, 3, "DKK Auction", seller3);
    auction3.currency = .DKK;

    const events = [_]Event{
        Event{ .auction_added = .{ .at = 1589702116, .auction = auction1 } },
        Event{ .auction_added = .{ .at = 1589702119, .auction = auction2 } },
        Event{ .auction_added = .{ .at = 1589702122, .auction = auction3 } },
    };
    defer {
        for (events) |event| {
            event.deinit(allocator);
        }
    }

    // Write and read back
    try persistence.writeEvents(allocator, file_path, &events);

    const read_events = try persistence.readEvents(allocator, file_path);
    defer {
        for (read_events) |event| {
            event.deinit(allocator);
        }
        allocator.free(read_events);
    }

    // Verify
    try testing.expectEqual(@as(usize, 3), read_events.len);
    try testing.expectEqual(Currency.VAC, read_events[0].auction_added.auction.currency);
    try testing.expectEqual(Currency.SEK, read_events[1].auction_added.auction.currency);
    try testing.expectEqual(Currency.DKK, read_events[2].auction_added.auction.currency);

    // Clean up
    std.fs.cwd().deleteFile(file_path) catch {};
}
