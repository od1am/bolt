const std = @import("std");
const Allocator = std.mem.Allocator;

const torrent = @import("torrent.zig");
const file = torrent.File;

pub const FileIO = struct {
    allocator: Allocator,
    files: []const file,
    file_handles: []std.fs.File,
    piece_length: usize,

    pub fn init(allocator: Allocator, files: []const file, piece_length: usize, output_dir: []const u8) !FileIO {
        var file_handles = try allocator.alloc(std.fs.File, files.len);
        errdefer allocator.free(file_handles);

        for (files, 0..) |f, i| {
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, f.path });
            defer allocator.free(file_path);

            const dir_path = std.fs.path.dirname(file_path) orelse "";
            try std.fs.cwd().makePath(dir_path);

            file_handles[i] = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        }

        return FileIO{
            .allocator = allocator,
            .files = files,
            .file_handles = file_handles,
            .piece_length = piece_length,
        };
    }

    pub fn deinit(self: *FileIO) void {
        for (self.file_handles) |handle| {
            handle.close();
        }
        self.allocator.free(self.file_handles);
    }

    pub fn writeBlock(self: *FileIO, piece_index: usize, begin: usize, block: []const u8) !void {
        var remaining_data = block;
        var current_offset = piece_index * self.piece_length + begin;

        for (self.files, 0..) |files, i| {
            if (current_offset >= files.length) {
                current_offset -= files.length;
                continue;
            }

            const write_size = @min(files.length - current_offset, remaining_data.len);
            try self.file_handles[i].seekTo(current_offset);
            try self.file_handles[i].writeAll(remaining_data[0..write_size]);

            remaining_data = remaining_data[write_size..];
            current_offset = 0;

            if (remaining_data.len == 0) break;
        }
    }
};
