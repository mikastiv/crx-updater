const std = @import("std");
const mksv = @import("mksv");

const manifest_json = "manifest.json";
const locale_dir = "_locales/en";

const ChromeExtension = struct {
    id: []u8,
    version: []u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    defer {
        stdout.flush() catch {};
        stderr.flush() catch {};
    }

    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 2) {
        try stderr.writeAll("usage: crx-updater <nix file path>\n");
        return error.MissingFilepath;
    }

    const nix_filename = args[1];
    const nix_file = try std.Io.Dir.cwd().openFile(io, nix_filename, .{ .mode = .read_write });
    defer nix_file.close(io);

    var nix_file_reader = nix_file.reader(io, &.{});
    var nix_file_buffer: [4096]u8 = undefined;
    var nix_file_writer = nix_file.writer(io, &nix_file_buffer);

    const nix_reader = &nix_file_reader.interface;
    const nix_writer = &nix_file_writer.interface;

    var extensions: std.ArrayList(ChromeExtension) = try .initCapacity(allocator, 64);

    var blocks: std.ArrayList([]const u8) = try .initCapacity(allocator, 32);

    const nix_file_content = try nix_reader.allocRemaining(allocator, .limited(1024 * 1024 * 64));
    try nix_file.setLength(io, 0);
    try nix_file_writer.seekTo(0);

    var indent: ?usize = null;

    const id_marker = "id = \"";
    const hash_marker = "sha256 = \"";
    const version_marker = "version = \"";

    const create_chromium_ext_text = "(createChromiumExtension {";
    var haystack = nix_file_content;
    while (std.mem.indexOf(u8, haystack, create_chromium_ext_text)) |index| {
        const start = index + create_chromium_ext_text.len;
        const end = std.mem.indexOf(u8, haystack[start..], "})") orelse break;
        const chunk = haystack[start .. start + end];

        if (indent == null) {
            const count = std.mem.lastIndexOfScalar(u8, chunk, '\n').?;
            indent = chunk.len - count - 1;
        }

        var extension: ChromeExtension = .{
            .id = "",
            .version = "",
        };

        const id_index = std.mem.indexOf(u8, chunk, id_marker);
        const version_index = std.mem.indexOf(u8, chunk, version_marker);

        if (id_index == null or version_index == null) {
            try stderr.writeAll("warning: missing data for an extension... skipping\n");
            haystack = haystack[index + end ..];
            continue;
        }

        const id = std.mem.sliceTo(chunk[id_index.? + id_marker.len ..], ';');
        extension.id = try allocator.dupe(u8, std.mem.trim(u8, id, " \""));

        const version = std.mem.sliceTo(chunk[version_index.? + version_marker.len ..], ';');
        extension.version = try allocator.dupe(u8, std.mem.trim(u8, version, " \""));

        try extensions.appendBounded(extension);

        try blocks.appendBounded(haystack[0 .. start + id_index.?]);

        haystack = haystack[start + end ..];
    } else {
        try blocks.appendBounded(haystack);
    }

    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const tmp_allocator = arena.allocator();

    for (extensions.items, blocks.items[0 .. blocks.items.len - 1]) |extension, block| {
        _ = arena.reset(.retain_capacity);

        const browser_version = try getChromeVersion(tmp_allocator, io);

        const parent = "/tmp";
        var tmp = try std.Io.Dir.openDirAbsolute(io, parent, .{});
        defer tmp.close(io);

        const filename = try makeTempName(tmp_allocator, io);

        const zip_archive, const hash = try downloadCrxFile(tmp_allocator, io, tmp, filename, browser_version, extension.id);
        defer tmp.deleteFile(io, filename) catch {};
        defer zip_archive.close(io);

        var zip_buffer: [1024]u8 = undefined;
        var zip_reader = zip_archive.reader(io, &zip_buffer);

        const tempdir = try makeTempName(tmp_allocator, io);

        try tmp.createDir(io, tempdir, .default_dir);
        defer tmp.deleteTree(io, tempdir) catch {};

        var dest = try tmp.openDir(io, tempdir, .{});
        defer dest.close(io);

        const locale = try extractManifestAndLocale(tmp_allocator, &zip_reader, dest);

        const manifest = try dest.openFile(io, manifest_json, .{});
        defer manifest.close(io);

        const root = try parseJsonFile(tmp_allocator, io, manifest);

        var extension_name = if (root.object.get("name")) |name| name.string else "unknown";
        if (std.mem.startsWith(u8, extension_name, "__MSG")) {
            if (try lookupLocaleName(tmp_allocator, io, dest, locale.?, extension_name)) |name| {
                extension_name = name;
            }
        }

        const latest_version = if (root.object.get("version")) |ver|
            ver.string
        else
            return error.NoVersionInManifest;

        const params_offset = 2;
        try nix_writer.writeAll(block);
        try nix_writer.writeAll(id_marker);
        try nix_writer.writeAll(extension.id);
        try nix_writer.writeAll("\";\n");
        try nix_writer.splatByteAll(' ', indent.? + params_offset);
        try nix_writer.writeAll(hash_marker);
        try nix_writer.writeAll(hash);
        try nix_writer.writeAll("\";\n");
        try nix_writer.splatByteAll(' ', indent.? + params_offset);
        try nix_writer.writeAll(version_marker);
        try nix_writer.writeAll(latest_version);
        try nix_writer.writeAll("\";\n");
        try nix_writer.splatByteAll(' ', indent.?);

        try stdout.print("{s}\n  current: {s}\n  latest:  {s}\n", .{
            extension_name,
            extension.version,
            latest_version,
        });
    }

    try nix_writer.writeAll(blocks.getLast());

    try nix_writer.flush();
}

fn lookupLocaleName(
    allocator: std.mem.Allocator,
    io: std.Io,
    dest: std.Io.Dir,
    locale: []const u8,
    placeholder: []const u8,
) !?[]const u8 {
    const locale_file = try dest.openFile(io, locale, .{});
    defer locale_file.close(io);

    const root = try parseJsonFile(allocator, io, locale_file);

    var it = std.mem.tokenizeScalar(u8, placeholder, '_');
    _ = it.next();

    const key = it.next() orelse return null;
    const value = root.object.get(key) orelse return null;

    const message = value.object.get("message") orelse return null;
    return message.string;
}

fn parseJsonFile(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !std.json.Value {
    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;

    var json_reader = std.json.Reader.init(allocator, reader);
    const parsed = try std.json.parseFromTokenSource(std.json.Value, allocator, &json_reader, .{});

    return parsed.value;
}

fn extractManifestAndLocale(
    allocator: std.mem.Allocator,
    reader: *std.Io.File.Reader,
    dest: std.Io.Dir,
) !?[]const u8 {
    var it: std.zip.Iterator = try .init(reader);
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var found_manifest = false;
    var locale: ?[]const u8 = null;
    while (try it.next()) |entry| {
        const filename = filename_buffer[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename);

        if (std.mem.eql(u8, filename, manifest_json)) {
            try entry.extract(reader, .{}, &filename_buffer, dest);
            found_manifest = true;
        } else if (std.mem.startsWith(u8, filename, locale_dir) and
            std.mem.endsWith(u8, filename, "messages.json"))
        {
            locale = try allocator.dupe(u8, filename);
            try entry.extract(reader, .{}, &filename_buffer, dest);
        }

        if (found_manifest and locale != null) break;
    }

    if (!found_manifest) return error.NoManifestInArchive;

    return locale;
}

fn getChromeVersion(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const chrome_result = try std.process.run(allocator, io, .{
        .argv = &.{ "chromium", "--version" },
    });

    const raw_version = chrome_result.stdout;
    const chrome_str = std.mem.sliceTo(raw_version, ' ');
    const version_str = raw_version[chrome_str.len + 1 ..];
    const version = std.mem.sliceTo(version_str, '.');

    return version;
}

fn downloadCrxFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    filename: []const u8,
    browser_version: []const u8,
    id: []const u8,
) !struct { std.Io.File, []u8 } {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    var response_writer: std.Io.Writer.Allocating = .init(allocator);

    const http_response = try client.fetch(.{
        .location = .{ .url = try makeDownloadUrl(allocator, browser_version, id) },
        .response_writer = &response_writer.writer,
    });

    if (http_response.status != .ok) return error.DownloadFailed;

    var sha256: std.crypto.hash.sha2.Sha256 = .init(.{});
    sha256.update(response_writer.written());
    const hash = sha256.finalResult();

    var buffer: [64]u8 = undefined;
    const base32 = mksv.hash.nix32.encode(&buffer, &hash);
    const file_hash = try std.fmt.allocPrint(allocator, "sha256:{s}", .{base32});

    var reader = std.Io.Reader.fixed(response_writer.written());
    const magic = try reader.takeInt(u32, .little);
    if (magic != 0x34327243) return error.InvalidCrxFile;
    reader.toss(4); // version
    const header_length = try reader.takeInt(u32, .little);
    reader.toss(header_length);

    const file = try dir.createFile(io, filename, .{ .read = true });
    var file_reader = file.reader(io, &.{});
    errdefer dir.deleteFile(io, filename) catch {};
    errdefer file.close(io);

    try file.writeStreamingAll(io, reader.buffered());
    try file_reader.seekTo(0);

    return .{ file, file_hash };
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

fn makeTempName(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const rng: std.Random.IoSource = .{ .io = io };
    const random_bytes = rng.interface().int(u64);
    const name = try std.fmt.allocPrint(allocator, "tmp_{x}", .{random_bytes});

    return name;
}
