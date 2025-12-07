const std = @import("std");
const models = @import("models.zig");
const ArrayList = std.array_list.Managed;

const Auction = models.Auction;
const Bid = models.Bid;
const AuctionState = models.AuctionState;
const AuctionError = models.AuctionError;
const AuctionId = models.AuctionId;
const User = models.User;
const Event = models.Event;
const Command = models.Command;
const AuctionTypeOptions = models.AuctionTypeOptions;

pub const Repository = std.AutoHashMap(AuctionId, struct {
    auction: Auction,
    state: AuctionState,
});

pub const HandleResult = union(enum) {
    success: Event,
    failure: AuctionError,
};

fn validateBid(bid: Bid, auction: Auction) !void {
    const seller_id = auction.seller.userId();
    const bidder_id = bid.bidder.userId();

    if (std.mem.eql(u8, bidder_id, seller_id)) {
        return AuctionError.SellerCannotPlaceBids;
    }
}

fn updateStateWithTime(allocator: std.mem.Allocator, state: AuctionState, now: i64) !AuctionState {
    switch (state) {
        .awaiting_start => |s| {
            if (now > s.start_time and now < s.expiry) {
                return AuctionState{
                    .ongoing = .{
                        .bids = ArrayList(Bid).init(allocator),
                        .expiry = s.expiry,
                        .options = s.options,
                    },
                };
            } else if (now >= s.expiry) {
                return AuctionState{
                    .has_ended = .{
                        .bids = ArrayList(Bid).init(allocator),
                        .expiry = s.expiry,
                        .options = s.options,
                    },
                };
            }
            return state;
        },
        .ongoing => |s| {
            if (now >= s.expiry) {
                return AuctionState{
                    .has_ended = .{
                        .bids = s.bids,
                        .expiry = s.expiry,
                        .options = s.options,
                    },
                };
            }
            return state;
        },
        .has_ended => return state,
    }
}

pub fn addBidToState(allocator: std.mem.Allocator, bid: Bid, state: *AuctionState) !void {
    const now = bid.at;
    const updated_state = try updateStateWithTime(allocator, state.*, now);
    state.* = updated_state;

    switch (state.*) {
        .awaiting_start => return AuctionError.AuctionHasNotStarted,
        .ongoing => |*s| {
            if (s.bids.items.len == 0) {
                const time_frame = s.options.time_frame_seconds;
                const new_expiry = @max(s.expiry, now + time_frame);
                s.expiry = new_expiry;
                try s.bids.append(bid);
            } else {
                const highest_bid = s.bids.items[s.bids.items.len - 1];
                const highest_amount = highest_bid.amount;
                const min_raise = s.options.min_raise;
                const time_frame = s.options.time_frame_seconds;

                if (bid.amount > highest_amount + min_raise) {
                    const new_expiry = @max(s.expiry, now + time_frame);
                    s.expiry = new_expiry;
                    try s.bids.append(bid);
                } else {
                    return AuctionError.MustPlaceBidOverHighestBid;
                }
            }
        },
        .has_ended => return AuctionError.AuctionHasEnded,
    }
}

pub fn handle(
    allocator: std.mem.Allocator,
    command: Command,
    repository: *Repository,
) !HandleResult {
    switch (command) {
        .add_auction => |cmd| {
            const auction_id = cmd.auction.id;

            if (repository.contains(auction_id)) {
                return HandleResult{ .failure = AuctionError.AuctionAlreadyExists };
            }

            const empty_state = AuctionState.initEmpty(allocator, cmd.auction);
            try repository.put(auction_id, .{
                .auction = cmd.auction,
                .state = empty_state,
            });

            return HandleResult{
                .success = Event{
                    .auction_added = .{
                        .at = cmd.at,
                        .auction = cmd.auction,
                    },
                },
            };
        },
        .place_bid => |cmd| {
            const auction_id = cmd.bid.auction_id;

            var entry = repository.getPtr(auction_id) orelse {
                return HandleResult{ .failure = AuctionError.UnknownAuction };
            };

            validateBid(cmd.bid, entry.auction) catch |err| {
                return HandleResult{ .failure = err };
            };

            addBidToState(allocator, cmd.bid, &entry.state) catch |err| {
                return HandleResult{ .failure = err };
            };

            return HandleResult{
                .success = Event{
                    .bid_accepted = .{
                        .at = cmd.at,
                        .bid = cmd.bid,
                    },
                },
            };
        },
    }
}

pub fn getBids(state: AuctionState) []const Bid {
    switch (state) {
        .awaiting_start => return &[_]Bid{},
        .ongoing => |s| return s.bids.items,
        .has_ended => |s| return s.bids.items,
    }
}

pub fn getWinnerAndPrice(state: AuctionState) ?struct { amount: i64, winner: []const u8 } {
    switch (state) {
        .has_ended => |s| {
            if (s.bids.items.len > 0) {
                const highest_bid = s.bids.items[s.bids.items.len - 1];
                if (highest_bid.amount >= s.options.reserve_price) {
                    return .{
                        .amount = highest_bid.amount,
                        .winner = highest_bid.bidder.userId(),
                    };
                }
            }
            return null;
        },
        else => return null,
    }
}
