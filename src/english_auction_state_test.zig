const std = @import("std");
const testing = std.testing;
const models = @import("models.zig");
const domain = @import("domain.zig");

const Auction = models.Auction;
const Bid = models.Bid;
const AuctionState = models.AuctionState;
const User = models.User;
const Currency = models.Currency;
const AuctionType = models.AuctionType;
const AuctionTypeOptions = models.AuctionTypeOptions;
const AuctionError = models.AuctionError;

// Sample data
const sample_starts_at: i64 = 1000;
const sample_ends_at: i64 = 2000;

fn createSampleEnglishAuction(allocator: std.mem.Allocator) !Auction {
    return Auction{
        .id = 1,
        .starts_at = sample_starts_at,
        .title = try allocator.dupe(u8, "Test English Auction"),
        .expiry = sample_ends_at,
        .seller = User{
            .buyer_or_seller = .{
                .user_id = try allocator.dupe(u8, "seller1"),
                .name = try allocator.dupe(u8, "Seller One"),
            },
        },
        .typ = AuctionType{
            .timed_ascending = AuctionTypeOptions{
                .reserve_price = 0,
                .min_raise = 0,
                .time_frame_seconds = 0,
            },
        },
        .currency = Currency.VAC,
    };
}

fn createBid(allocator: std.mem.Allocator, auction_id: i64, buyer_id: []const u8, buyer_name: []const u8, amount: i64, at: i64) !Bid {
    return Bid{
        .auction_id = auction_id,
        .bidder = User{
            .buyer_or_seller = .{
                .user_id = try allocator.dupe(u8, buyer_id),
                .name = try allocator.dupe(u8, buyer_name),
            },
        },
        .amount = amount,
        .at = at,
    };
}

test "english auction - can add bid to empty state" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);

    // Add bid should succeed
    try domain.addBidToState(allocator, bid1, &state);

    // State should be ongoing
    try testing.expect(state == .ongoing);
}

test "english auction - can add second bid" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);

    // Add second bid should succeed (higher than first)
    try domain.addBidToState(allocator, bid2, &state);

    // State should still be ongoing
    try testing.expect(state == .ongoing);
}

test "english auction - can end" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time first
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    // Advance time past expiry
    try domain.advanceTime(allocator, &state, sample_ends_at + 1);

    // State should transition to has_ended
    try testing.expect(state == .has_ended);

    // Should have no bids
    const bids = domain.getBids(state);
    try testing.expectEqual(@as(usize, 0), bids.len);
}

test "english auction - ended with two bids" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Advance time past expiry
    try domain.advanceTime(allocator, &state, sample_ends_at + 1);

    // State should transition to has_ended
    try testing.expect(state == .has_ended);

    // Should have two bids
    const bids = domain.getBids(state);
    try testing.expectEqual(@as(usize, 2), bids.len);
}

test "english auction - can't bid after auction has ended" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    // Advance time past expiry
    try domain.advanceTime(allocator, &state, sample_ends_at + 1);

    // Try to add bid after auction ended
    const bid_after_end = try createBid(allocator, 1, "buyer3", "Buyer Three", 200, sample_ends_at + 10);
    const result = domain.addBidToState(allocator, bid_after_end, &state);

    // Should fail with AuctionHasEnded error
    try testing.expectError(AuctionError.AuctionHasEnded, result);

    // Clean up the bid that wasn't added
    bid_after_end.deinit(allocator);
}

test "english auction - can get winner and price from an auction" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Advance time past expiry
    try domain.advanceTime(allocator, &state, sample_ends_at + 1);

    // Get winner and price
    const result = domain.getWinnerAndPrice(state);

    try testing.expect(result != null);
    if (result) |r| {
        try testing.expectEqual(@as(i64, 150), r.amount);
        try testing.expectEqualStrings("buyer2", r.winner);
    }
}

test "english auction - can't place bid lower than highest bid" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Try to place bid lower than highest
    const bid_low = try createBid(allocator, 1, "buyer3", "Buyer Three", 120, sample_starts_at + 30);
    const result = domain.addBidToState(allocator, bid_low, &state);

    // Should fail with MustPlaceBidOverHighestBid error
    try testing.expectError(AuctionError.MustPlaceBidOverHighestBid, result);

    // Clean up the bid that wasn't added
    bid_low.deinit(allocator);
}

test "english auction - can't place equal bid to highest bid" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    // Try to place equal bid
    const bid_equal = try createBid(allocator, 1, "buyer2", "Buyer Two", 100, sample_starts_at + 20);
    const result = domain.addBidToState(allocator, bid_equal, &state);

    // Should fail with MustPlaceBidOverHighestBid error
    try testing.expectError(AuctionError.MustPlaceBidOverHighestBid, result);

    // Clean up the bid that wasn't added
    bid_equal.deinit(allocator);
}

test "english auction - with min raise requirement" {
    const allocator = testing.allocator;

    var auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    // Set min raise to 10
    auction.typ = AuctionType{
        .timed_ascending = AuctionTypeOptions{
            .reserve_price = 0,
            .min_raise = 10,
            .time_frame_seconds = 0,
        },
    };

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    // Try to bid only 5 more than highest (less than min raise of 10)
    const bid_too_low = try createBid(allocator, 1, "buyer2", "Buyer Two", 105, sample_starts_at + 20);
    const result_low = domain.addBidToState(allocator, bid_too_low, &state);
    try testing.expectError(AuctionError.MustPlaceBidOverHighestBid, result_low);
    bid_too_low.deinit(allocator);

    // Bid exactly min raise over highest should succeed
    const bid_exact = try createBid(allocator, 1, "buyer2", "Buyer Two", 111, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid_exact, &state);
}

test "english auction - with reserve price" {
    const allocator = testing.allocator;

    var auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    // Set reserve price to 200
    auction.typ = AuctionType{
        .timed_ascending = AuctionTypeOptions{
            .reserve_price = 200,
            .min_raise = 0,
            .time_frame_seconds = 0,
        },
    };

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Advance time past expiry
    try domain.advanceTime(allocator, &state, sample_ends_at + 1);

    // Get winner and price - should be null because highest bid (150) is below reserve (200)
    const result = domain.getWinnerAndPrice(state);
    try testing.expect(result == null);
}

test "english auction - with reserve price met" {
    const allocator = testing.allocator;

    var auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    // Set reserve price to 100
    auction.typ = AuctionType{
        .timed_ascending = AuctionTypeOptions{
            .reserve_price = 100,
            .min_raise = 0,
            .time_frame_seconds = 0,
        },
    };

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Advance time past expiry
    try domain.advanceTime(allocator, &state, sample_ends_at + 1);

    // Get winner and price - should succeed because highest bid (150) meets reserve (100)
    const result = domain.getWinnerAndPrice(state);
    try testing.expect(result != null);
    if (result) |r| {
        try testing.expectEqual(@as(i64, 150), r.amount);
        try testing.expectEqualStrings("buyer2", r.winner);
    }
}

test "english auction - bids are visible during ongoing state" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Bids should be visible while ongoing
    const bids = domain.getBids(state);
    try testing.expectEqual(@as(usize, 2), bids.len);
}

test "english auction - can't bid before auction starts" {
    const allocator = testing.allocator;

    const auction = try createSampleEnglishAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Try to bid before auction starts
    const bid_early = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at - 10);
    const result = domain.addBidToState(allocator, bid_early, &state);

    // Should fail with AuctionHasNotStarted error
    try testing.expectError(AuctionError.AuctionHasNotStarted, result);

    // Clean up the bid that wasn't added
    bid_early.deinit(allocator);
}
