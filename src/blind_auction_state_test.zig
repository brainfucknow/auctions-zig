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
const SingleSealedBidOptions = models.SingleSealedBidOptions;
const SealedBidType = models.SealedBidType;

// Sample data
const sample_starts_at: i64 = 1000;
const sample_ends_at: i64 = 2000;

fn createSampleAuction(allocator: std.mem.Allocator) !Auction {
    return Auction{
        .id = 1,
        .starts_at = sample_starts_at,
        .title = try allocator.dupe(u8, "Test Auction"),
        .expiry = sample_ends_at,
        .seller = User{
            .buyer_or_seller = .{
                .user_id = try allocator.dupe(u8, "seller1"),
                .name = try allocator.dupe(u8, "Seller One"),
            },
        },
        .typ = AuctionType{
            .single_sealed_bid = SingleSealedBidOptions{
                .reserve_price = 0,
                .sealed_bid_type = SealedBidType.blind,
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

test "blind auction - can add bid to empty state" {
    const allocator = testing.allocator;

    const auction = try createSampleAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);

    // Add bid should succeed
    try domain.addBidToState(allocator, bid1, &state);

    // State should be sealed_bid_ongoing
    try testing.expect(state == .sealed_bid_ongoing);
}

test "blind auction - can add second bid" {
    const allocator = testing.allocator;

    const auction = try createSampleAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);

    // Add second bid should succeed
    try domain.addBidToState(allocator, bid2, &state);

    // State should still be sealed_bid_ongoing
    try testing.expect(state == .sealed_bid_ongoing);
}

test "blind auction - can end" {
    const allocator = testing.allocator;

    const auction = try createSampleAuction(allocator);
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

    // State should transition to sealed_bid_disclosing
    try testing.expect(state == .sealed_bid_disclosing);

    // Bids should be disclosed (visible)
    const bids = domain.getBids(state);
    try testing.expectEqual(@as(usize, 2), bids.len);
}

test "blind auction - can get winner and price from ended auction" {
    const allocator = testing.allocator;

    const auction = try createSampleAuction(allocator);
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

test "blind auction - bids are hidden during ongoing state" {
    const allocator = testing.allocator;

    const auction = try createSampleAuction(allocator);
    defer auction.deinit(allocator);

    var state = AuctionState.initEmpty(allocator, auction);
    defer state.deinit(allocator);

    // Advance to auction start time
    try domain.advanceTime(allocator, &state, sample_starts_at + 1);

    const bid1 = try createBid(allocator, 1, "buyer1", "Buyer One", 100, sample_starts_at + 10);
    try domain.addBidToState(allocator, bid1, &state);

    const bid2 = try createBid(allocator, 1, "buyer2", "Buyer Two", 150, sample_starts_at + 20);
    try domain.addBidToState(allocator, bid2, &state);

    // Bids should be hidden while ongoing
    const bids = domain.getBids(state);
    try testing.expectEqual(@as(usize, 0), bids.len);
}
