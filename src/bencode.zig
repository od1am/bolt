const std = @import("std");
const Allocator = std.mem.Allocator;
const StringArrayHashMap = std.StringArrayHashMap;

pub const BencodeValue = union(enum) {
    integer: i64,
    string: []const u8,
    list: []BencodeValue,
    dict: StringArrayHashMap(BencodeValue),

    pub fn deinit(self: *BencodeValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .list => |list| {
                for (list) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(list);
            },
            .dict => |*d| {
                var it = d.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                d.deinit();
            },
            else => {},
        }
    }
};

pub const BencodeParseError = error{
    InvalidFormat,
    KeysNotSorted,
    OutOfMemory,
    InvalidInteger,
    InvalidStringLength,
};

pub fn parse(allocator: Allocator, input: []const u8) BencodeParseError!BencodeValue {
    var pos: usize = 0;
    const value = try parseValue(allocator, input, &pos);
    if (pos != input.len) return error.InvalidFormat;
    return value;
}

fn parseValue(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    if (pos.* >= input.len) return error.InvalidFormat;
    switch (input[pos.*]) {
        'i' => return parseInteger(input, pos),
        '0'...'9' => return parseString(allocator, input, pos),
        'l' => return parseList(allocator, input, pos),
        'd' => return parseDict(allocator, input, pos),
        else => return error.InvalidFormat,
    }
}

fn parseInteger(input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    pos.* += 1;
    const start = pos.*;
    while (pos.* < input.len and input[pos.*] != 'e') : (pos.* += 1) {}
    if (pos.* >= input.len) return error.InvalidFormat;

    const num_str = input[start..pos.*];
    pos.* += 1;

    const num = std.fmt.parseInt(i64, num_str, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return error.InvalidInteger,
    };
    return BencodeValue{ .integer = num };
}

fn parseString(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    const start = pos.*;
    while (pos.* < input.len and input[pos.*] != ':') : (pos.* += 1) {}
    if (pos.* >= input.len) return error.InvalidFormat;

    const len_str = input[start..pos.*];
    pos.* += 1;

    const len = std.fmt.parseInt(usize, len_str, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return error.InvalidStringLength,
    };

    if (pos.* + len > input.len) return error.InvalidFormat;
    const str = input[pos.* .. pos.* + len];
    pos.* += len;

    const copied_str = try allocator.dupe(u8, str);
    return BencodeValue{ .string = copied_str };
}

fn parseList(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    pos.* += 1;
    var list = std.ArrayList(BencodeValue).init(allocator);
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit();
    }

    while (pos.* < input.len and input[pos.*] != 'e') {
        try list.append(try parseValue(allocator, input, pos));
    }
    if (pos.* >= input.len) return error.InvalidFormat;
    pos.* += 1;

    return BencodeValue{ .list = try list.toOwnedSlice() };
}

fn parseDict(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    pos.* += 1;
    var dict = StringArrayHashMap(BencodeValue).init(allocator);
    errdefer {
        var it = dict.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        dict.deinit();
    }

    var prev_key: ?[]const u8 = null;

    while (pos.* < input.len and input[pos.*] != 'e') {
        var key_bencode = try parseString(allocator, input, pos);
        defer key_bencode.deinit(allocator);
        const key = key_bencode.string;

        const value = try parseValue(allocator, input, pos);

        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);

        if (prev_key) |pk| {
            if (std.mem.order(u8, pk, key_copy) != .lt) return error.KeysNotSorted;
        }

        try dict.put(key_copy, value);
        prev_key = key_copy;
    }
    if (pos.* >= input.len) return error.InvalidFormat;
    pos.* += 1;

    return BencodeValue{ .dict = dict };
}

// Helper functions to extract values from parsed BencodeValue
pub fn extractString(allocator: Allocator, dict: StringArrayHashMap(BencodeValue), key: []const u8) ![]const u8 {
    const value = dict.get(key) orelse return error.InvalidFormat;
    if (value != .string) return error.InvalidFormat;
    return try allocator.dupe(u8, value.string);
}

pub fn extractInteger(dict: StringArrayHashMap(BencodeValue), key: []const u8) !i64 {
    const value = dict.get(key) orelse return error.InvalidFormat;
    if (value != .integer) return error.InvalidFormat;
    return value.integer;
}

// Serialize a BencodeValue back to its encoded form
pub fn serialize(allocator: Allocator, value: BencodeValue) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try serializeValue(&buffer, value);
    return buffer.toOwnedSlice();
}

fn serializeValue(buffer: *std.ArrayList(u8), value: BencodeValue) !void {
    switch (value) {
        .integer => |num| try buffer.writer().print("i{}e", .{num}),
        .string => |str| try buffer.writer().print("{}:{s}", .{ str.len, str }),
        .list => |list| {
            try buffer.append('l');
            for (list) |item| {
                try serializeValue(buffer, item);
            }
            try buffer.append('e');
        },
        .dict => |dict| {
            try buffer.append('d');
            var it = dict.iterator();
            while (it.next()) |entry| {
                try serializeValue(buffer, BencodeValue{ .string = entry.key_ptr.* });
                try serializeValue(buffer, entry.value_ptr.*);
            }
            try buffer.append('e');
        },
    }
}

test "parse integer" {
    const allocator = std.testing.allocator;
    const data = "i1337e";
    var result = try parse(allocator, data);
    defer result.deinit(allocator);

    try std.testing.expect(result == .integer);
    try std.testing.expectEqual(result.integer, 1337);
}

test "parse string" {
    const allocator = std.testing.allocator;
    const data = "12:Hello World!";
    var result = try parse(allocator, data);
    defer result.deinit(allocator);

    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings(result.string, "Hello World!");
}

test "parse list" {
    const allocator = std.testing.allocator;
    const data = "li1337ee";
    var result = try parse(allocator, data);
    defer result.deinit(allocator);

    try std.testing.expect(result == .list);
    try std.testing.expectEqual(result.list.len, 1);
    try std.testing.expect(result.list[0] == .integer);
    try std.testing.expectEqual(result.list[0].integer, 1337);
}

test "parse dict" {
    const allocator = std.testing.allocator;
    const data = "d3:key5:valuee";
    var result = try parse(allocator, data);
    defer result.deinit(allocator);

    try std.testing.expect(result == .dict);
    const value = result.dict.get("key");
    try std.testing.expect(value != null);
    try std.testing.expect(value.? == .string);
    try std.testing.expectEqualStrings(value.?.string, "value");
}

test "nested structures" {
    const allocator = std.testing.allocator;
    const data = "d4:listli1ei2ei3ee3:str5:hello5:valuei42ee";
    var result = try parse(allocator, data);
    defer result.deinit(allocator);

    try std.testing.expect(result == .dict);

    // Check list
    const list_value = result.dict.get("list");
    try std.testing.expect(list_value != null);
    try std.testing.expect(list_value.? == .list);
    try std.testing.expectEqual(list_value.?.list.len, 3);
    try std.testing.expectEqual(list_value.?.list[0].integer, 1);
    try std.testing.expectEqual(list_value.?.list[1].integer, 2);
    try std.testing.expectEqual(list_value.?.list[2].integer, 3);

    // Check string
    const str_value = result.dict.get("str");
    try std.testing.expect(str_value != null);
    try std.testing.expect(str_value.? == .string);
    try std.testing.expectEqualStrings(str_value.?.string, "hello");

    // Check integer
    const int_value = result.dict.get("value");
    try std.testing.expect(int_value != null);
    try std.testing.expect(int_value.? == .integer);
    try std.testing.expectEqual(int_value.?.integer, 42);
}

test "serialize and parse" {
    const allocator = std.testing.allocator;

    // Test with a simpler structure to avoid memory leaks
    const value1 = BencodeValue{ .integer = 1337 };
    const serialized1 = try serialize(allocator, value1);
    defer allocator.free(serialized1);

    var parsed1 = try parse(allocator, serialized1);
    defer parsed1.deinit(allocator);

    try std.testing.expect(parsed1 == .integer);
    try std.testing.expectEqual(parsed1.integer, 1337);

    // Test with a string value - storing in var since we need to deinit
    var value2 = BencodeValue{ .string = try allocator.dupe(u8, "test string") };
    defer value2.deinit(allocator);

    const serialized2 = try serialize(allocator, value2);
    defer allocator.free(serialized2);

    var parsed2 = try parse(allocator, serialized2);
    defer parsed2.deinit(allocator);

    try std.testing.expect(parsed2 == .string);
    try std.testing.expectEqualStrings(parsed2.string, "test string");

    // Test with a list value
    var list = try allocator.alloc(BencodeValue, 2);
    list[0] = BencodeValue{ .integer = 1 };
    list[1] = BencodeValue{ .integer = 2 };

    var value3 = BencodeValue{ .list = list };
    defer value3.deinit(allocator);

    const serialized3 = try serialize(allocator, value3);
    defer allocator.free(serialized3);

    var parsed3 = try parse(allocator, serialized3);
    defer parsed3.deinit(allocator);

    try std.testing.expect(parsed3 == .list);
    try std.testing.expectEqual(parsed3.list.len, 2);
    try std.testing.expect(parsed3.list[0] == .integer);
    try std.testing.expectEqual(parsed3.list[0].integer, 1);
    try std.testing.expect(parsed3.list[1] == .integer);
    try std.testing.expectEqual(parsed3.list[1].integer, 2);
}
