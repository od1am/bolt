const std = @import("std");
const Allocator = std.mem.Allocator;
const BencodeValue = @import("bencode.zig").BencodeValue;
const StringArrayHashMap = std.StringArrayHashMap;

// Struct to represent the torrent file metadata
pub const TorrentFile = struct {
    announce: []const u8, // Tracker URL
    info: InfoDict, // Info dictionary from the torrent file
    info_raw: []const u8, // Raw bencoded info dictionary

    pub fn deinit(self: *TorrentFile, allocator: Allocator) void {
        allocator.free(self.announce);
        self.info.deinit(allocator);
        allocator.free(self.info_raw);
    }

    pub fn calculateInfoHash(self: *const TorrentFile) ![20]u8 {
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(self.info_raw);
        return hasher.finalResult();
    }
};

// Struct to represent the 'info' dictionary in the torrent file
pub const InfoDict = struct {
    name: []const u8, // Name of the torrent
    piece_length: usize, // Size of each piece in bytes
    pieces: []const u8, // Concatenated SHA-1 hashes of pieces
    length: ?usize, // Total size of the file (single-file torrent)
    files: ?[]File, // List of files (multi-file torrent)

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

// Struct to represent a file in a multi-file torrent
pub const File = struct {
    path: []const u8, // Path to the file
    length: usize, // Size of the file in bytes

    pub fn deinit(self: *File, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

// Parse the torrent file from Bencoded data
pub fn parseTorrentFile(allocator: Allocator, data: []const u8) !TorrentFile {
    const bencode = @import("bencode.zig");
    var bencode_value = try bencode.parse(allocator, data);
    defer bencode_value.deinit(allocator);

    if (bencode_value != .dict) return error.InvalidFormat;

    const announce = try extractString(allocator, bencode_value.dict, "announce");
    const info_value = bencode_value.dict.get("info") orelse return error.InvalidFormat;
    const info_raw = try serializeBencodeValue(allocator, info_value);
    const info_dict = try extractInfoDict(allocator, info_value);

    return TorrentFile{
        .announce = announce,
        .info = info_dict,
        .info_raw = info_raw,
    };
}

// Extract the 'info' dictionary from the Bencoded value
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

// Extract a list of files from the Bencoded value
fn extractFiles(allocator: Allocator, files_list: []BencodeValue) ![]File {
    var files = try allocator.alloc(File, files_list.len);
    for (files_list, 0..) |file_value, i| {
        if (file_value != .dict) return error.InvalidFormat;
        const path = try extractString(allocator, file_value.dict, "path");
        const length = try extractInteger(file_value.dict, "length");
        files[i] = File{ .path = path, .length = length };
    }
    return files;
}

// Extract a string from the Bencoded dictionary
fn extractString(allocator: Allocator, dict: StringArrayHashMap(BencodeValue), key: []const u8) ![]const u8 {
    const value = dict.get(key) orelse return error.InvalidFormat;
    if (value != .string) return error.InvalidFormat;
    return try allocator.dupe(u8, value.string);
}

// Extract an integer from the Bencoded dictionary
fn extractInteger(dict: StringArrayHashMap(BencodeValue), key: []const u8) !usize {
    const value = dict.get(key) orelse return error.InvalidFormat;
    if (value != .integer) return error.InvalidFormat;
    return @intCast(value.integer);
}

// Calculate the SHA-1 info hash of the 'info' dictionary
pub fn calculateInfoHash(_: Allocator, info_raw: []const u8) ![20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(info_raw);
    return hasher.finalResult();
}

// Serialize a BencodeValue to a byte array
fn serializeBencodeValue(allocator: Allocator, value: BencodeValue) ![]const u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try serializeValue(&buffer, value);
    return buffer.toOwnedSlice();
}

// Helper function to serialize BencodeValue
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
