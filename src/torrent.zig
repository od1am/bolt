const std = @import("std");
const Allocator = std.mem.Allocator;
const BencodeValue = @import("bencode.zig").BencodeValue;
const StringArrayHashMap = std.StringArrayHashMap;

pub const TorrentFile = struct {
    announce_url: ?[]const u8 = null,
    announce_list: ?[][]const u8 = null,
    info: InfoDict,
    info_raw: []const u8,

    pub fn deinit(self: *TorrentFile, allocator: Allocator) void {
        if (self.announce_url) |url| {
            allocator.free(url);
        }
        if (self.announce_list) |announce_list| {
            for (announce_list) |url| {
                allocator.free(url);
            }
            allocator.free(announce_list);
        }
        self.info.deinit(allocator);
        allocator.free(self.info_raw);
    }

    pub fn calculateInfoHash(self: *const TorrentFile) ![20]u8 {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(self.info_raw);

        // Print the raw info dictionary for debugging
        std.debug.print("Calculating info hash from raw data of length {}\n", .{self.info_raw.len});
        std.debug.print("First 20 bytes of info_raw: ", .{});
        for (self.info_raw[0..@min(20, self.info_raw.len)]) |b| {
            std.debug.print("{x:0>2}", .{b});
        }
        std.debug.print("\n", .{});

        const hash = hasher.finalResult();

        // Print the calculated info hash
        std.debug.print("Calculated info hash: ", .{});
        for (hash) |b| {
            std.debug.print("{x:0>2}", .{b});
        }
        std.debug.print("\n", .{});

        return hash;
    }
};

pub const InfoDict = struct {
    name: []const u8,
    piece_length: usize,
    pieces: []const u8,
    length: ?usize,
    files: ?[]File,

    pub fn deinit(self: *InfoDict, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.pieces);
        if (self.files) |files| {
            for (files) |*file| {
                file.deinit(allocator);
            }
            allocator.free(files);
        }
    }
};

pub const File = struct {
    path: []const u8,
    length: usize,

    pub fn deinit(self: *File, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub const Torrent_State = enum {
    queued,
    checking_for_files,
    downloading_metadata,
    finished,
    seeding,
    missing_files,
    downloading,
    stopped,
};

pub fn parseTorrentFile(allocator: Allocator, data: []const u8) !TorrentFile {
    const bencode = @import("bencode.zig");
    var bencode_value = try bencode.parse(allocator, data);
    defer bencode_value.deinit(allocator);

    if (bencode_value != .dict) return error.InvalidFormat;

    // Extract announce URL if present
    var announce: ?[]const u8 = null;
    if (bencode_value.dict.get("announce")) |announce_value| {
        if (announce_value == .string) {
            announce = try allocator.dupe(u8, announce_value.string);
        }
    }

    const info_value = bencode_value.dict.get("info") orelse return error.InvalidFormat;
    const info_raw = try serializeBencodeValue(allocator, info_value);
    const info_dict = try extractInfoDict(allocator, info_value);

    // Extract announce-list if present
    var announce_list: ?[][]const u8 = null;
    if (bencode_value.dict.get("announce-list")) |announce_list_value| {
        if (announce_list_value == .list) {
            var urls = std.ArrayList([]const u8).init(allocator);
            defer urls.deinit();

            for (announce_list_value.list) |tier| {
                if (tier == .list) {
                    for (tier.list) |url_value| {
                        if (url_value == .string) {
                            try urls.append(try allocator.dupe(u8, url_value.string));
                        }
                    }
                }
            }

            if (urls.items.len > 0) {
                announce_list = try urls.toOwnedSlice();
            }
        }
    }

    return TorrentFile{
        .announce_url = announce,
        .announce_list = announce_list,
        .info = info_dict,
        .info_raw = info_raw,
    };
}

fn extractInfoDict(allocator: Allocator, info_value: BencodeValue) !InfoDict {
    if (info_value != .dict) return error.InvalidFormat;

    const name = try extractString(allocator, info_value.dict, "name");
    const piece_length = try extractInteger(info_value.dict, "piece length");
    const pieces = try extractString(allocator, info_value.dict, "pieces");
    var length: ?usize = null;
    if (info_value.dict.get("length")) |_| {
        length = try extractInteger(info_value.dict, "length");
    }

    var files: ?[]File = null;
    if (info_value.dict.get("files")) |files_value| {
        if (files_value != .list) return error.InvalidFormat;
        files = try extractFiles(allocator, files_value.list);
    }

    return InfoDict{
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .length = length,
        .files = files,
    };
}

fn extractFiles(allocator: Allocator, files_list: []BencodeValue) ![]File {
    var files = try allocator.alloc(File, files_list.len);
    for (files_list, 0..) |file_value, i| {
        if (file_value != .dict) return error.InvalidFormat;

        // Get the length first
        const length = try extractInteger(file_value.dict, "length");

        // Handle the path field properly - it should be a list of path components
        const path_value = file_value.dict.get("path") orelse return error.InvalidFormat;
        if (path_value != .list) return error.InvalidFormat;

        // Extract path from list of components
        var path_buf = std.ArrayList(u8).init(allocator);
        defer path_buf.deinit();

        for (path_value.list, 0..) |component, j| {
            if (component != .string) return error.InvalidFormat;
            // Add path separator if not the first component
            if (j > 0) {
                try path_buf.append('/');
            }
            try path_buf.appendSlice(component.string);
        }

        // Duplicate the path string to ensure it's correctly allocated
        const path = try allocator.dupe(u8, path_buf.items);

        files[i] = File{ .path = path, .length = length };
    }
    return files;
}

fn extractString(allocator: Allocator, dict: StringArrayHashMap(BencodeValue), key: []const u8) ![]const u8 {
    const value = dict.get(key) orelse return error.InvalidFormat;
    if (value != .string) return error.InvalidFormat;
    return try allocator.dupe(u8, value.string);
}

fn extractInteger(dict: StringArrayHashMap(BencodeValue), key: []const u8) !usize {
    const value = dict.get(key) orelse return error.InvalidFormat;
    if (value != .integer) return error.InvalidFormat;
    return @intCast(value.integer);
}

pub fn calculateInfoHash(_: Allocator, info_raw: []const u8) ![20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(info_raw);
    return hasher.finalResult();
}

fn serializeBencodeValue(allocator: Allocator, value: BencodeValue) ![]const u8 {
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
