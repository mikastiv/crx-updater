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

    const id = "cjpalhdlnbpafiamejdnhcphjbkeiagm";

    const chrome_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "chromium", "--version" },
    });
    const browser_version = getChromeVersion(chrome_result.stdout);

    const filename = try makeTempName(allocator);

    const zip_archive = try downloadCrxFile(allocator, filename, browser_version, id);
    defer std.fs.deleteFileAbsolute(filename) catch {};
    defer zip_archive.close();

    var zip_buffer: [1024]u8 = undefined;
    var zip_reader = zip_archive.reader(&zip_buffer);

    const tempdir = try makeTempName(allocator);
    try std.fs.makeDirAbsolute(tempdir);
    defer std.fs.deleteTreeAbsolute(tempdir) catch {};

    var dest = try std.fs.openDirAbsolute(tempdir, .{});
    defer dest.close();

    try std.zip.extract(dest, &zip_reader, .{});

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

fn getChromeVersion(raw_version: []const u8) []const u8 {
    const chrome_str = std.mem.sliceTo(raw_version, ' ');
    const version_str = raw_version[chrome_str.len + 1 ..];
    const version = std.mem.sliceTo(version_str, '.');
    return version;
}

fn downloadCrxFile(
    allocator: std.mem.Allocator,
    filename: []const u8,
    browser_version: []const u8,
    id: []const u8,
) !std.fs.File {
    var client: std.http.Client = .{ .allocator = allocator };
    var response_writer: std.Io.Writer.Allocating = .init(allocator);

    const http_response = try client.fetch(.{
        .location = .{ .url = try makeDownloadUrl(allocator, browser_version, id) },
        .response_writer = &response_writer.writer,
    });

    if (http_response.status != .ok) return error.DownloadFailed;

    var reader = std.Io.Reader.fixed(response_writer.written());
    const magic = try reader.takeInt(u32, .little);
    if (magic != 0x34327243) return error.InvalidCrxFile;
    reader.toss(4); // version
    const header_length = try reader.takeInt(u32, .little);
    reader.toss(header_length);

    const file = try std.fs.createFileAbsolute(filename, .{ .read = true });
    errdefer std.fs.deleteDirAbsolute(filename) catch {};
    errdefer file.close();

    try file.writeAll(reader.buffered());
    try file.seekTo(0);

    return file;
}

fn makeDownloadUrl(
    allocator: std.mem.Allocator,
    browser_version: []const u8,
    id: []const u8,
) ![]u8 {
    const template = "https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx2,crx3&prodversion={s}&x=id%3D{s}%26installsource%3Dondemand%26uc";
    const url = try std.fmt.allocPrint(allocator, template, .{ browser_version, id });
    return url;
}

fn makeTempName(allocator: std.mem.Allocator) ![]u8 {
    const random_bytes = std.crypto.random.int(u64);
    const name = try std.fmt.allocPrint(allocator, "/tmp/tmp_{x}", .{random_bytes});
    return name;
}
