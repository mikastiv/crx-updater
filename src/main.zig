const std = @import("std");

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const tempdir = try makeTempDirname(allocator);
    const filename = "1password.zip";

    var unzip = std.process.Child.init(&.{ "unzip", "-d", tempdir, filename }, allocator);
    unzip.stdin_behavior = .Ignore;
    unzip.stdout_behavior = .Ignore;
    unzip.stderr_behavior = .Ignore;
    _ = try unzip.spawnAndWait();

    var dest = try std.fs.openDirAbsolute(tempdir, .{});
    defer std.fs.deleteTreeAbsolute(tempdir) catch {};
    defer dest.close();

    const manifest = try dest.openFile("manifest.json", .{});
    defer manifest.close();

    var file_buffer: [1024]u8 = undefined;
    var file_reader = manifest.reader(&file_buffer);
    const reader = &file_reader.interface;

    var json_reader = std.json.Reader.init(allocator, reader);
    const parsed = try std.json.parseFromTokenSource(std.json.Value, allocator, &json_reader, .{});

    const root = parsed.value;
    if (root.object.get("version")) |version| {
        std.debug.print("{s}\n", .{version.string});
    }
}

fn makeTempDirname(allocator: std.mem.Allocator) ![]u8 {
    const random_bytes = std.crypto.random.int(u64);
    const name = try std.fmt.allocPrint(allocator, "/tmp/tmp_{x}", .{random_bytes});
    return name;
}
