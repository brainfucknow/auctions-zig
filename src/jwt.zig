const std = @import("std");
const models = @import("models.zig");
const base64 = std.base64;
const json = std.json;

const User = models.User;

pub fn decodeJwtUser(allocator: std.mem.Allocator, encoded: []const u8) !User {
    const decoder = base64.standard.Decoder;
    const decoded_size = try decoder.calcSizeForSlice(encoded);

    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);

    try decoder.decode(decoded, encoded);

    const parsed = try json.parseFromSlice(json.Value, allocator, decoded, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    const sub = obj.get("sub") orelse return error.InvalidJWT;
    const sub_str = sub.string;

    const u_typ = obj.get("u_typ") orelse return error.InvalidJWT;
    const u_typ_str = u_typ.string;

    if (std.mem.eql(u8, u_typ_str, "0")) {
        const name = obj.get("name") orelse return error.InvalidJWT;
        const name_str = name.string;

        return User{
            .buyer_or_seller = .{
                .user_id = try allocator.dupe(u8, sub_str),
                .name = try allocator.dupe(u8, name_str),
            },
        };
    } else if (std.mem.eql(u8, u_typ_str, "1")) {
        return User{
            .support = .{
                .user_id = try allocator.dupe(u8, sub_str),
            },
        };
    }

    return error.InvalidJWT;
}
