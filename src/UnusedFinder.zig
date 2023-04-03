const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const ClangAstNode = @import("./ClangAstNode.zig");
const StringPool = @import("./StringPool.zig");

// config:
allocator: Allocator,
/// Only source files somewhere within this dir are considered in scope.
project_root: []const u8,
/// Typically "build", e.g. for the cmake build dir.
/// Used in case the compiler refers to non-absolute file paths.
effective_cwd: []const u8,
/// Optional list of roots of third-party projects within the project_root.
/// Source files within these directories are considered out of scope.
third_party_paths_in_project_root: []const []const u8 = &[_][]const u8{},

// tables of info
strings: StringPool = .{},
id_to_loc: std.AutoHashMapUnmanaged(u64, u32) = .{},
used_locs: std.AutoHashMapUnmanaged(u32, void) = .{},

// bookkeeping buffers
current_file: []const u8 = "",
current_line: []const u8 = "",
current_line_buf: [16]u8 = undefined,
current_file_buf: [4096]u8 = undefined,

pub fn deinit(self: *@This()) void {
    self.strings.deinit(self.allocator);
    self.id_to_loc.deinit(self.allocator);
    self.used_locs.deinit(self.allocator);
    self.* = undefined;
}

/// Order is undefined.
pub fn iterator(self: *const @This()) Iterator {
    return .{ .it = self.strings.dedup_table.keyIterator() };
}
pub const Iterator = struct {
    it: @TypeOf(@as(StringPool, undefined).dedup_table).KeyIterator,
    pub fn next(self: *@This()) ?u32 {
        return (self.it.next() orelse return null).*;
    }
};

const kinds_of_interest = std.ComptimeStringMap(void, .{
    .{"FunctionDecl"},
    .{"CXXMethodDecl"},
    .{"CXXConstructorDecl"},
    .{"CXXConversionDecl"},
    // (It's hard to imagine a scenario when it's useful to know that a destructor is unused.)
});

pub fn handleNode(self: *@This(), node: ClangAstNode) !void {
    // We need to record the current source position, because it might be omitted from later nodes.
    try self.recordLocInfo(node);

    if (!kinds_of_interest.has(node.kind)) return;

    const col = node.col;

    if (self.current_file.len == 0 or self.current_line.len == 0 or col.len == 0) {
        // Nodes without loc info are out of scope for this analysis.
        // e.g. compiler builtins.
        return;
    }
    if (node.is_implicit) {
        // Implicit nodes are things like default constructors and the __invoke method of lambda expressions.
        // (Note that lambda expressions *do* get analyzed, because they contain a class with an operator() method,
        //  and that method is *not* implicit.)
        return;
    }

    const id = try std.fmt.parseInt(u64, node.id, 0);

    var loc_i: u32 = undefined;
    if (node.previous_decl.len > 0) {
        // This is the definition of a previously prototyped function.
        // Use the prototype location as the true location.
        const previous_id = try std.fmt.parseInt(u64, node.previous_decl, 0);
        loc_i = self.id_to_loc.get(previous_id) orelse return error.PreviouslDeclNotFound;
    } else {
        // New location.
        var loc_buf: [0x1000]u8 = undefined;
        const loc_str = try std.fmt.bufPrint(loc_buf[0..], "{s}:{s}:{s}", .{
            self.current_file,
            self.current_line,
            node.col,
        });
        loc_i = try self.strings.putString(self.allocator, loc_str);
    }
    try self.id_to_loc.putNoClobber(self.allocator, id, loc_i);

    if (node.is_used) {
        _ = try self.used_locs.put(self.allocator, loc_i, {});
    }
}

fn recordLocInfo(self: *@This(), node: ClangAstNode) !void {
    if (node.file.len > 0) {
        // Resolve the path to the canonical form that we want.
        var buf: [0x2000]u8 = undefined;
        var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&buf);
        var allocator = fixed_buffer_allocator.allocator();

        var file = node.file;
        if (!std.fs.path.isAbsolute(file)) {
            file = try std.fs.path.join(allocator, &[_][]const u8{ self.effective_cwd, file });
        }
        file = try std.fs.path.relative(allocator, self.project_root, file);

        // Determine if we care about nodes from this file.
        var in_scope = true;
        if (std.mem.startsWith(u8, file, "../")) {
            in_scope = false;
        } else {
            for (self.third_party_paths_in_project_root) |third_party_root| {
                if (normalizedPathStartsWith(file, third_party_root)) {
                    in_scope = false;
                    break;
                }
            }
        }
        if (!in_scope) {
            file = "";
        }

        // Save the canonicalized name, even if it's "".
        try self.saveStr(file, &self.current_file_buf, &self.current_file);
    }

    if (self.current_file.len > 0 and node.line.len > 0) {
        try self.saveStr(node.line, &self.current_line_buf, &self.current_line);
    }
}
fn saveStr(_: *const @This(), src: []const u8, buf: anytype, dest_slice: *[]const u8) !void {
    if (src.len > buf.len) return error.StringTooLong;
    std.mem.copy(u8, buf, src);
    dest_slice.* = buf[0..src.len];
}

/// Seems like this could go in the std lib.
/// Both paths must be normalized and either both be absolute or both be relative.
fn normalizedPathStartsWith(descendent: []const u8, ancestor: []const u8) bool {
    assert(ancestor.len > 0 and descendent.len > 0);
    assert(std.fs.path.isAbsolute(ancestor) == std.fs.path.isAbsolute(descendent)); // can't compare abs vs rel.
    assert(ancestor[ancestor.len - 1] != '/'); // ancestor must be normalized to not end with a '/'.
    if (ancestor.len < descendent.len) {
        return std.mem.startsWith(u8, descendent, ancestor) and descendent[ancestor.len] == '/';
    }
    if (ancestor.len > descendent.len) return false;
    return std.mem.eql(u8, ancestor, descendent);
}
