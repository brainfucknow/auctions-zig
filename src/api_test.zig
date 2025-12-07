const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const models = @import("models.zig");
const domain = @import("domain.zig");

const AppState = api.AppState;

// Test JWT payloads (base64 encoded JSON)
// seller1: {"sub":"a1", "name":"Test", "u_typ":"0"}
const seller1_jwt = "eyJzdWIiOiJhMSIsICJuYW1lIjoiVGVzdCIsICJ1X3R5cCI6IjAifQo=";
// buyer1: {"sub":"a2", "name":"Buyer", "u_typ":"0"}
const buyer1_jwt = "eyJzdWIiOiJhMiIsICJuYW1lIjoiQnV5ZXIiLCAidV90eXAiOiIwIn0K";

// Helper to create auction JSON with dates in the future
fn createAuctionJson(allocator: std.mem.Allocator, id: i64) ![]u8 {
    // Use dates in the future to ensure auction is active
    return try std.fmt.allocPrint(allocator,
        \\{{"id":{d},"startsAt":"2020-01-01T10:00:00.000Z","endsAt":"2030-01-01T10:00:00.000Z","title":"First auction","currency":"VAC"}}
    , .{id});
}

const add_bid_req_json =
    \\{"amount":11}
;

fn createTestState(allocator: std.mem.Allocator) !AppState {
    const test_events_file = "test/tmp/api-test-events.jsonl";

    // Ensure test directory exists
    std.fs.cwd().makePath("test/tmp") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_events_file) catch {};

    return AppState{
        .allocator = allocator,
        .repository = domain.Repository.init(allocator),
        .mutex = std.Thread.Mutex{},
        .events_file = test_events_file,
    };
}

fn expectJsonContains(actual: []const u8, expected_substring: []const u8) !void {
    if (std.mem.indexOf(u8, actual, expected_substring) == null) {
        std.debug.print("\nExpected to find: {s}\n", .{expected_substring});
        std.debug.print("In: {s}\n", .{actual});
        return error.TestExpectedEqual;
    }
}

test "add auction - possible to add auction" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    const auction_json = try createAuctionJson(allocator, 1);
    defer allocator.free(auction_json);

    const response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );
    defer allocator.free(response);

    // Verify response contains auction added event
    try expectJsonContains(response, "\"$type\":\"AuctionAdded\"");
    try expectJsonContains(response, "\"id\":1");
    try expectJsonContains(response, "\"title\":\"First auction\"");
    try expectJsonContains(response, "\"currency\":\"VAC\"");
}

test "add auction - not possible to add same auction twice" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    const auction_json = try createAuctionJson(allocator, 1);
    defer allocator.free(auction_json);

    // Add auction first time
    const response1 = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );
    defer allocator.free(response1);

    // Try to add same auction again - should fail
    const result = api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );

    try testing.expectError(error.AuctionAlreadyExists, result);
}

test "add auction - returns added auction" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    const auction_json = try createAuctionJson(allocator, 1);
    defer allocator.free(auction_json);

    // Add auction
    const add_response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );
    defer allocator.free(add_response);

    // Get the auction
    const get_response = try api.handleRequest(
        allocator,
        &state,
        .GET,
        "/auctions/1",
        null,
        "",
    );
    defer allocator.free(get_response);

    // Verify response contains auction details
    try expectJsonContains(get_response, "\"id\":1");
    try expectJsonContains(get_response, "\"title\":\"First auction\"");
    try expectJsonContains(get_response, "\"currency\":\"VAC\"");
    try expectJsonContains(get_response, "\"bids\":[]");
    try expectJsonContains(get_response, "\"winner\":null");
    try expectJsonContains(get_response, "\"winnerPrice\":null");
}

test "add auction - returns added auctions in list" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    const auction_json = try createAuctionJson(allocator, 1);
    defer allocator.free(auction_json);

    // Add auction
    const add_response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );
    defer allocator.free(add_response);

    // Get all auctions
    const get_response = try api.handleRequest(
        allocator,
        &state,
        .GET,
        "/auctions",
        null,
        "",
    );
    defer allocator.free(get_response);

    // Verify response is a list containing the auction
    try expectJsonContains(get_response, "[");
    try expectJsonContains(get_response, "\"id\":1");
    try expectJsonContains(get_response, "\"title\":\"First auction\"");
    try expectJsonContains(get_response, "\"currency\":\"VAC\"");
}

test "add bids - possible to add bid to auction" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    const auction_json = try createAuctionJson(allocator, 1);
    defer allocator.free(auction_json);

    // Add auction first
    const add_auction_response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );
    defer allocator.free(add_auction_response);

    // Add bid
    const add_bid_response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions/1/bids",
        buyer1_jwt,
        add_bid_req_json,
    );
    defer allocator.free(add_bid_response);

    // Verify response contains bid accepted event
    try expectJsonContains(add_bid_response, "\"$type\":\"BidAccepted\"");
    try expectJsonContains(add_bid_response, "\"auction\":1");
    try expectJsonContains(add_bid_response, "\"amount\":11");
}

test "add bids - possible to see the added bids" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    const auction_json = try createAuctionJson(allocator, 1);
    defer allocator.free(auction_json);

    // Add auction
    const add_auction_response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions",
        seller1_jwt,
        auction_json,
    );
    defer allocator.free(add_auction_response);

    // Add bid
    const add_bid_response = try api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions/1/bids",
        buyer1_jwt,
        add_bid_req_json,
    );
    defer allocator.free(add_bid_response);

    // Get auction with bids
    const get_response = try api.handleRequest(
        allocator,
        &state,
        .GET,
        "/auctions/1",
        null,
        "",
    );
    defer allocator.free(get_response);

    // Verify bid is in the response
    try expectJsonContains(get_response, "\"bids\":[");
    try expectJsonContains(get_response, "\"amount\":11");
    try expectJsonContains(get_response, "\"bidder\":\"BuyerOrSeller|a2|Buyer\"");
}

test "add bids - not possible to add bid to non existent auction" {
    const allocator = testing.allocator;

    var state = try createTestState(allocator);
    defer state.deinit();

    // Try to add bid to non-existent auction
    const result = api.handleRequest(
        allocator,
        &state,
        .POST,
        "/auctions/2/bids",
        buyer1_jwt,
        add_bid_req_json,
    );

    try testing.expectError(error.UnknownAuction, result);
}
