// A content-addressable blob store where each blob is stored as
// /blobs/<sha256-hash/
const std = @import("std");
const Allocator = std.mem.Allocator;
const constants = @import("constants.zig");

const DIR = "blobs";
const HASH = std.crypto.hash.sha2.Sha256;

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

/// Stores file path src_abspath in blobs dir, returns its hex digest
pub fn store(gpa: Allocator, src_abspath: []const u8) !BlobInfo {
    var src = try std.fs.openFileAbsolute(src_abspath, .{});
    const src_bytes = try src.readToEndAlloc(gpa, constants.MAX_ATTACHMENT_BYTES);
    defer gpa.free(src_bytes);

    var digest: [HASH.digest_length]u8 = undefined;
    HASH.hash(src_bytes, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    var blob_path: [DIR.len + "/".len + HASH.digest_length * 2]u8 = undefined;
    _ = try std.fmt.bufPrint(&blob_path, "{s}/{s}", .{ DIR, &digest_hex });

    if (std.fs.cwd().statFile(&blob_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    }) |stat| {
        if (stat.kind == .file) {
            std.debug.print("blobstore: {s} already exists => skipped\n", .{digest_hex[0..7]});
            return .{
                .hash = digest_hex,
                .size = stat.size,
            };
        }
    }

    try std.fs.Dir.copyFile(
        try std.fs.openDirAbsolute(std.fs.path.dirname(src_abspath).?, .{}),
        std.fs.path.basename(src_abspath),
        std.fs.cwd(),
        &blob_path,
        .{},
    );

    std.debug.print("blobstore: {s} stored\n", .{digest_hex[0..7]});
    return .{
        .hash = digest_hex,
        .size = src_bytes.len,
    };
}
