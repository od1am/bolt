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
