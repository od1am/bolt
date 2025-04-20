const std = @import("std");
const testing = std.testing;
const torrent = @import("torrent.zig");
const bencode = @import("bencode.zig");
const Allocator = std.mem.Allocator;

// Sample torrent data for testing
const test_torrent_data =
    \\d8:announce35:http://tracker.example.com/announce4:infod6:lengthi1024e4:name8:test.txt12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaa7:privatei0eee
;

test "parseTorrentFile" {
    const allocator = testing.allocator;

    var torrent_file = try torrent.parseTorrentFile(allocator, test_torrent_data);
    defer torrent_file.deinit(allocator);

    // Test basic properties
    try testing.expectEqualStrings("http://tracker.example.com/announce", torrent_file.announce_url.?);
    try testing.expectEqualStrings("test.txt", torrent_file.info.name);
    try testing.expectEqual(@as(usize, 16384), torrent_file.info.piece_length);
    try testing.expectEqual(@as(usize, 1024), torrent_file.info.length.?);
    try testing.expectEqual(@as(usize, 20), torrent_file.info.pieces.len);
    try testing.expect(torrent_file.info.files == null);
}

// Test torrent data with multiple files
const test_multi_file_torrent_data =
    \\d8:announce35:http://tracker.example.com/announce4:infod5:filesld6:lengthi1024e4:pathl8:file1.txteeld6:lengthi2048e4:pathl8:file2.txteee4:name11:test_folder12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaa7:privatei0eee
;

test "parseTorrentFile with multiple files" {
    const allocator = testing.allocator;

    var torrent_file = try torrent.parseTorrentFile(allocator, test_multi_file_torrent_data);
    defer torrent_file.deinit(allocator);

    // Test basic properties
    try testing.expectEqualStrings("http://tracker.example.com/announce", torrent_file.announce_url.?);
    try testing.expectEqualStrings("test_folder", torrent_file.info.name);
    try testing.expectEqual(@as(usize, 16384), torrent_file.info.piece_length);
    try testing.expect(torrent_file.info.length == null);
    try testing.expectEqual(@as(usize, 20), torrent_file.info.pieces.len);

    // Test files
    try testing.expect(torrent_file.info.files != null);
    try testing.expectEqual(@as(usize, 2), torrent_file.info.files.?.len);
    try testing.expectEqualStrings("file1.txt", torrent_file.info.files.?[0].path);
    try testing.expectEqual(@as(usize, 1024), torrent_file.info.files.?[0].length);
    try testing.expectEqualStrings("file2.txt", torrent_file.info.files.?[1].path);
    try testing.expectEqual(@as(usize, 2048), torrent_file.info.files.?[1].length);
}

test "calculateInfoHash" {
    const allocator = testing.allocator;

    var torrent_file = try torrent.parseTorrentFile(allocator, test_torrent_data);
    defer torrent_file.deinit(allocator);

    const info_hash = try torrent_file.calculateInfoHash();

    // We can't easily predict the exact hash value, but we can check it's not all zeros
    var is_all_zeros = true;
    for (info_hash) |byte| {
        if (byte != 0) {
            is_all_zeros = false;
            break;
        }
    }

    try testing.expect(!is_all_zeros);
    try testing.expectEqual(@as(usize, 20), info_hash.len);
}
