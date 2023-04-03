const StringPool = @This();

const std = @import("std");

buf: std.ArrayListUnmanaged(u8) = .{},
dedup_table: std.HashMapUnmanaged(u32, void, Context, 20) = .{},

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.dedup_table.deinit(allocator);
    self.buf.deinit(allocator);
    self.* = undefined;
}

pub fn getString(self: @This(), i: u32) [:0]const u8 {
    // Couldn't figure out how to use std.mem.span() here.
    const bytes = self.buf.items;
    var end: usize = i;
    while (bytes[end] != 0) end += 1;
    return bytes[i..end :0];
}

pub fn putString(self: *@This(), allocator: std.mem.Allocator, s: []const u8) !u32 {
    const gop = try self.dedup_table.getOrPutContextAdapted(
        allocator,
        s,
        AdaptedContext{ .pool = self },
        Context{ .pool = self },
    );

    if (gop.found_existing) return gop.key_ptr.*;

    const index = @intCast(u32, self.buf.items.len);
    try self.buf.ensureUnusedCapacity(allocator, s.len + 1);
    self.buf.appendSliceAssumeCapacity(s);
    self.buf.appendAssumeCapacity(0);
    gop.key_ptr.* = index;

    return index;
}

const Context = struct {
    pool: *const StringPool,
    pub fn hash(self: @This(), k: u32) u64 {
        return std.hash.Wyhash.hash(0, self.pool.getString(k));
    }
    pub fn eql(_: @This(), _: u32, _: u32) bool {
        unreachable; // unused.
    }
};
const AdaptedContext = struct {
    pool: *const StringPool,
    pub fn hash(_: @This(), k: []const u8) u64 {
        return std.hash.Wyhash.hash(0, k);
    }
    pub fn eql(self: @This(), a: []const u8, b: u32) bool {
        return std.mem.eql(u8, a, self.pool.getString(b));
    }
};
