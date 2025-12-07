const std = @import("std");
const testing = std.testing;
const models = @import("models.zig");
const json = std.json;

const AuctionTypeOptions = models.AuctionTypeOptions;

test "english auction type - can serialize default options" {
    const allocator = testing.allocator;

    const options = AuctionTypeOptions{
        .reserve_price = 0,
        .min_raise = 0,
        .time_frame_seconds = 0,
    };

    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    try json.stringify(options, .{}, string.writer());

    const expected = "\"English|0|0|0\"";
    try testing.expectEqualStrings(expected, string.items);
}

test "english auction type - can deserialize default options" {
    const allocator = testing.allocator;

    const json_str = "\"English|0|0|0\"";

    const parsed = try json.parseFromSlice(AuctionTypeOptions, allocator, json_str, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 0), parsed.value.reserve_price);
    try testing.expectEqual(@as(i64, 0), parsed.value.min_raise);
    try testing.expectEqual(@as(i64, 0), parsed.value.time_frame_seconds);
}

test "english auction type - can serialize options with values" {
    const allocator = testing.allocator;

    const options = AuctionTypeOptions{
        .reserve_price = 10,
        .min_raise = 20,
        .time_frame_seconds = 30,
    };

    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();

    try json.stringify(options, .{}, string.writer());

    const expected = "\"English|10|20|30\"";
    try testing.expectEqualStrings(expected, string.items);
}

test "english auction type - can deserialize options with values" {
    const allocator = testing.allocator;

    const json_str = "\"English|10|20|30\"";

    const parsed = try json.parseFromSlice(AuctionTypeOptions, allocator, json_str, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 10), parsed.value.reserve_price);
    try testing.expectEqual(@as(i64, 20), parsed.value.min_raise);
    try testing.expectEqual(@as(i64, 30), parsed.value.time_frame_seconds);
}

test "english auction type - round trip serialization" {
    const allocator = testing.allocator;

    const original = AuctionTypeOptions{
        .reserve_price = 100,
        .min_raise = 50,
        .time_frame_seconds = 3600,
    };

    // Serialize
    var string = std.ArrayList(u8).init(allocator);
    defer string.deinit();
    try json.stringify(original, .{}, string.writer());

    // Deserialize
    const parsed = try json.parseFromSlice(AuctionTypeOptions, allocator, string.items, .{});
    defer parsed.deinit();

    // Should match original
    try testing.expectEqual(original.reserve_price, parsed.value.reserve_price);
    try testing.expectEqual(original.min_raise, parsed.value.min_raise);
    try testing.expectEqual(original.time_frame_seconds, parsed.value.time_frame_seconds);
}

test "english auction type - deserialization fails on invalid format" {
    const allocator = testing.allocator;

    const invalid_json = "\"Invalid|format\"";

    const result = json.parseFromSlice(AuctionTypeOptions, allocator, invalid_json, .{});

    try testing.expectError(error.InvalidAuctionType, result);
}

test "english auction type - deserialization fails on non-English type" {
    const allocator = testing.allocator;

    const invalid_json = "\"French|0|0|0\"";

    const result = json.parseFromSlice(AuctionTypeOptions, allocator, invalid_json, .{});

    try testing.expectError(error.InvalidAuctionType, result);
}

test "english auction type - deserialization fails on invalid numbers" {
    const allocator = testing.allocator;

    const invalid_json = "\"English|abc|def|ghi\"";

    const result = json.parseFromSlice(AuctionTypeOptions, allocator, invalid_json, .{});

    try testing.expectError(error.InvalidCharacter, result);
}
