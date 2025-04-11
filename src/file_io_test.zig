const std = @import("std");
const testing = std.testing;
const FileIO = @import("file_io.zig").FileIO;
const File = @import("torrent.zig").File;
const Allocator = std.mem.Allocator;

test "FileIO initialization" {
    const allocator = testing.allocator;

    // Create a temporary directory for testing
    const test_dir = "test_output";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files array
    const files = [_]File{
        .{
            .path = "test1.txt",
            .length = 1024,
        },
        .{
            .path = "subdir/test2.txt",
            .length = 2048,
        },
    };

    // Initialize FileIO
    var file_io = try FileIO.init(allocator, &files, 16384, test_dir);
    defer file_io.deinit();

    // Verify file handles were created
    try testing.expectEqual(@as(usize, 2), file_io.file_handles.len);

    // Check that the files exist
    const test1_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "test1.txt" });
    defer allocator.free(test1_path);
    const test2_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "subdir/test2.txt" });
    defer allocator.free(test2_path);

    try testing.expect(std.fs.cwd().access(test1_path, .{}) catch false);
    try testing.expect(std.fs.cwd().access(test2_path, .{}) catch false);
}

test "FileIO write and read" {
    const allocator = testing.allocator;

    // Create a temporary directory for testing
    const test_dir = "test_output";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files array
    const files = [_]File{
        .{
            .path = "test_write.txt",
            .length = 1024,
        },
    };

    // Initialize FileIO
    var file_io = try FileIO.init(allocator, &files, 512, test_dir);
    defer file_io.deinit();

    // Test data to write
    const test_data = "Hello, world! This is a test.";

    // Write data to the first piece, at offset 0
    try file_io.writeBlock(0, 0, test_data);

    // Close the file handles to ensure data is written
    file_io.deinit();

    // Reopen the file and read the data
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "test_write.txt" });
    defer allocator.free(file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var buffer: [100]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);

    try testing.expectEqualStrings(test_data, buffer[0..bytes_read]);
}

test "FileIO write across multiple files" {
    const allocator = testing.allocator;

    // Create a temporary directory for testing
    const test_dir = "test_output";
    try std.fs.cwd().makeDir(test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files array with small sizes to test writing across files
    const files = [_]File{
        .{
            .path = "part1.txt",
            .length = 10, // First file can hold 10 bytes
        },
        .{
            .path = "part2.txt",
            .length = 10, // Second file can hold 10 bytes
        },
    };

    // Initialize FileIO with piece length of 20 (matches total file size)
    var file_io = try FileIO.init(allocator, &files, 20, test_dir);
    defer file_io.deinit();

    // Test data that spans both files
    const test_data = "This data spans two files!";

    // Write data to the first piece, at offset 0
    try file_io.writeBlock(0, 0, test_data);

    // Close the file handles to ensure data is written
    file_io.deinit();

    // Reopen the files and read the data
    const file1_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "part1.txt" });
    defer allocator.free(file1_path);

    const file2_path = try std.fs.path.join(allocator, &[_][]const u8{ test_dir, "part2.txt" });
    defer allocator.free(file2_path);

    const file1 = try std.fs.cwd().openFile(file1_path, .{});
    defer file1.close();

    const file2 = try std.fs.cwd().openFile(file2_path, .{});
    defer file2.close();

    var buffer1: [10]u8 = undefined;
    var buffer2: [10]u8 = undefined;

    const bytes_read1 = try file1.readAll(&buffer1);
    const bytes_read2 = try file2.readAll(&buffer2);

    // First file should have the first 10 bytes
    try testing.expectEqualStrings(test_data[0..10], buffer1[0..bytes_read1]);

    // Second file should have the next 10 bytes (or as many as fit)
    const expected_bytes = @min(10, test_data.len - 10);
    if (expected_bytes > 0) {
        try testing.expectEqualStrings(test_data[10..][0..expected_bytes], buffer2[0..bytes_read2]);
    }
}
