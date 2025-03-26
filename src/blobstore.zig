// A content-addressable blob store where each blob is stored as
// /blobs/<sha256-hash/
const std = @import("std");
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const c = zqlite.c;
const constants = @import("constants.zig");
const println = @import("util.zig").println;

const DIR = "blobs";
pub const HASH = std.crypto.hash.sha2.Sha256;

/// Assumes working dir is already correct (i.e. dir that contains .wm2k file)
pub fn ensureDir() !void {
    _ = std.fs.cwd().makeDir(DIR) catch |err| switch (err) {
        std.posix.MakeDirError.PathAlreadyExists => void,
        else => return err,
    };
}

pub const BlobInfo = struct {
    hash: [HASH.digest_length * 2]u8,
    size: u64,
};

/// Stores file at `src_abspath` in blobs dir, returns its hex digest
/// TODO: It takes ~9s to hash a 2.6GiB file, while gnu coreutils' sha256sum
/// command only takes 1.8s. There's room for improvement here. Also see
/// <https://github.com/ziglang/zig/issues/15916>
/// TODO: Regardless, this is now long-running-command territory.
/// I should implement some sort of progress report modal system soon.
pub fn store(gpa: Allocator, src_abspath: []const u8) !BlobInfo {
    var src_size_bytes: usize = 0;
    var hash_hex: [HASH.digest_length * 2]u8 = undefined;

    {
        var hash_timer = try std.time.Timer.start();
        defer {
            const hash_time_ms = hash_timer.read() / 1000 / 1000;
            if (hash_time_ms > 0) {
                println(
                    "blobstore: {s} took {d}ms to hash",
                    .{ hash_hex[0..7], hash_time_ms },
                );
            }
        }

        var src = try std.fs.openFileAbsolute(src_abspath, .{});
        defer src.close();

        var src_buf = try gpa.alloc(u8, 1024 * 1024 * 16);
        defer gpa.free(src_buf);

        // Stream src data into hasher:
        var hasher = HASH.init(.{});
        while (true) {
            const bytes_read = try src.read(src_buf);
            if (bytes_read == 0) break;
            src_size_bytes += bytes_read;
            hasher.update(src_buf[0..bytes_read]);
        }
        const hash_bytes = hasher.finalResult();
        hash_hex = std.fmt.bytesToHex(hash_bytes, .lower);
    }

    const file_path = try blob_path(hash_hex);

    if (std.fs.cwd().statFile(&file_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    }) |stat| {
        if (stat.kind == .file) {
            println("blobstore: {s} already exists => skipped", .{hash_hex[0..7]});
            return .{
                .hash = hash_hex,
                .size = stat.size,
            };
        }
    }

    try std.fs.Dir.copyFile(
        try std.fs.openDirAbsolute(std.fs.path.dirname(src_abspath).?, .{}),
        std.fs.path.basename(src_abspath),
        std.fs.cwd(),
        &file_path,
        .{},
    );

    println("blobstore: {s} stored", .{hash_hex[0..7]});
    return .{
        .hash = hash_hex,
        .size = src_size_bytes,
    };
}

pub fn blob_path(hash: [HASH.digest_length * 2]u8) ![DIR.len + "/".len + HASH.digest_length * 2]u8 {
    var path: [DIR.len + "/".len + HASH.digest_length * 2]u8 = undefined;
    _ = try std.fmt.bufPrint(&path, "{s}/{s}", .{ DIR, &hash });
    return path;
}

pub fn read(arena: Allocator, hash: [HASH.digest_length * 2]u8) ![]const u8 {
    const path = try blob_path(hash);
    return try std.fs.cwd().readFileAlloc(arena, &path, 9_223_372_036_854_775_807);
}

pub fn registerSqliteFunctions(conn: zqlite.Conn) !void {
    const ret = c.sqlite3_create_function(
        conn.conn,
        "blobstore_delete",
        1,
        c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC,
        null,
        sqlite_blobstore_delete,
        null,
        null,
    );

    if (ret != c.SQLITE_OK) {
        return error.CustomFunction;
    }
}

/// Sqlite application-defined function that deletes an on-disk blob
export fn sqlite_blobstore_delete(
    context: ?*c.sqlite3_context,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) void {
    _ = argc;
    const blob_hash = std.mem.span(c.sqlite3_value_text(argv[0].?));

    // TODO: how to handle errors in an sqlite application-defined function?
    var blobs_dir = std.fs.cwd().openDir(DIR, .{}) catch unreachable;
    defer blobs_dir.close();

    blobs_dir.deleteFile(blob_hash) catch |err| switch (err) {
        std.fs.Dir.DeleteFileError.FileNotFound => {
            println("blobstore: {s} does not exist => skipped", .{blob_hash[0..7]});
            c.sqlite3_result_int64(context, 0);
            return;
        },
        // TODO: how to handle errors in an sqlite application-defined function?
        else => unreachable,
    };

    println("blobstore: {s} deleted", .{blob_hash[0..7]});
    c.sqlite3_result_int64(context, 1);
}
