const std = @import("std");
const Allocator = std.mem.Allocator;
const StringArrayHashMap = std.StringArrayHashMap;

/// Bencode data type representation using tagged union
pub const BencodeValue = union(enum) {
    integer: i64, // i<number>e
    string: []const u8, // <length>:<string>
    list: []BencodeValue, // l...e
    dict: StringArrayHashMap(BencodeValue), // d...e

    /// Cleanup memory for nested structures
    pub fn deinit(self: *BencodeValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s), // Free allocated string
            .list => |list| {
                // Fix: Iterate over list slice directly
                for (list) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(list);
            },
            .dict => |*d| {
                // Free both keys and values in dictionary
                var it = d.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*); // Free key string
                    entry.value_ptr.deinit(allocator); // Recursively free value
                }
                d.deinit(); // Free dictionary container
            },
            else => {}, // Integer requires no cleanup
        }
    }
};

/// Bencode parsing error conditions
pub const BencodeParseError = error{
    InvalidFormat, // General structural issue
    KeysNotSorted, // Dictionary keys not in lex order
    OutOfMemory, // Allocation failure
    InvalidInteger, // Malformed integer (e.g., empty or non-digit chars)
    InvalidStringLength, // Invalid string length prefix
};

/// Main parsing entry point - validates complete input consumption
pub fn parse(allocator: Allocator, input: []const u8) BencodeParseError!BencodeValue {
    var pos: usize = 0;
    const value = try parseValue(allocator, input, &pos);
    // Ensure entire input was consumed
    if (pos != input.len) return error.InvalidFormat;
    return value;
}

/// Dispatches parsing based on initial character
fn parseValue(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    if (pos.* >= input.len) return error.InvalidFormat;
    switch (input[pos.*]) {
        'i' => return parseInteger(input, pos), // Integer type
        '0'...'9' => return parseString(allocator, input, pos), // String type
        'l' => return parseList(allocator, input, pos), // List type
        'd' => return parseDict(allocator, input, pos), // Dictionary type
        else => return error.InvalidFormat, // Unknown starting character
    }
}

/// Parse integer format: i<digits>e
fn parseInteger(input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    pos.* += 1; // Skip 'i'
    const start = pos.*;
    // Find closing 'e'
    while (pos.* < input.len and input[pos.*] != 'e') : (pos.* += 1) {}
    if (pos.* >= input.len) return error.InvalidFormat;

    const num_str = input[start..pos.*];
    pos.* += 1; // Skip 'e'

    // Convert string to integer with error mapping
    const num = std.fmt.parseInt(i64, num_str, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return error.InvalidInteger,
    };
    return BencodeValue{ .integer = num };
}

/// Parse string format: <length>:<string>
fn parseString(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    const start = pos.*;
    // Find colon separator
    while (pos.* < input.len and input[pos.*] != ':') : (pos.* += 1) {}
    if (pos.* >= input.len) return error.InvalidFormat;

    const len_str = input[start..pos.*];
    pos.* += 1; // Skip ':'

    // Parse length prefix
    const len = std.fmt.parseInt(usize, len_str, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return error.InvalidStringLength,
    };

    // Validate string bounds
    if (pos.* + len > input.len) return error.InvalidFormat;
    const str = input[pos.* .. pos.* + len];
    pos.* += len;

    // Copy string to allocated memory (original input is const)
    const copied_str = try allocator.dupe(u8, str);
    return BencodeValue{ .string = copied_str };
}

/// Parse list format: l<values>e
fn parseList(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    pos.* += 1; // Skip 'l'
    var list = std.ArrayList(BencodeValue).init(allocator);
    // Cleanup: If parsing fails, free already parsed elements
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit();
    }

    // Parse elements until closing 'e'
    while (pos.* < input.len and input[pos.*] != 'e') {
        try list.append(try parseValue(allocator, input, pos));
    }
    if (pos.* >= input.len) return error.InvalidFormat;
    pos.* += 1; // Skip 'e'

    return BencodeValue{ .list = try list.toOwnedSlice() };
}

/// Parse dictionary format: d<key-value pairs>e
fn parseDict(allocator: Allocator, input: []const u8, pos: *usize) BencodeParseError!BencodeValue {
    pos.* += 1; // Skip 'd'
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

    // Parse key-value pairs until closing 'e'
    while (pos.* < input.len and input[pos.*] != 'e') {
        // Create mutable BencodeValue for key
        var key_bencode = try parseString(allocator, input, pos);
        defer key_bencode.deinit(allocator);
        const key = key_bencode.string;

        // Parse associated value
        const value = try parseValue(allocator, input, pos);

        // Copy key to ensure ownership (original is tied to input)
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy); // Cleanup if value parsing fails

        // Validate key ordering (Bencode requirement)
        if (prev_key) |pk| {
            if (std.mem.order(u8, pk, key_copy) != .lt) return error.KeysNotSorted;
        }

        try dict.put(key_copy, value);
        prev_key = key_copy;
    }
    if (pos.* >= input.len) return error.InvalidFormat;
    pos.* += 1; // Skip 'e'

    return BencodeValue{ .dict = dict };
}
