const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const ClangAstNode = @import("./ClangAstNode.zig");
const StringPool = @import("./StringPool.zig");

const UnusedFinder = @This();

pub const Config = struct {
    /// Only source files somewhere within this dir are considered in scope.
    /// This must be an absolute, normalized path.
    project_root: []const u8,
    /// The directory the compiler executes in.
    /// Used in case the compiler refers to non-absolute file paths.
    /// This must be an absolute, normalized path.
    build_dir: []const u8,
    /// Optional list of roots of third-party projects within the project_root.
    /// Source files within these directories are considered out of scope.
    /// Must be normalized relative paths within the project root.
    third_party_paths_in_project_root: []const []const u8 = &[_][]const u8{},

    /// Resolves the given file to be relative to the project_root.
    /// Non-absolute input paths are resolved relative to build_dir.
    /// Returns "" if this file is out of scope.
    /// Allocations made with the given allocator are leaked;
    /// use an arena or other coarse bookkeeping to clean up the memory allocated by this function.
    pub fn resolvePath(self: *const @This(), allocator: Allocator, file: []const u8) ![]const u8 {
        var result = file;
        if (!std.fs.path.isAbsolute(file)) {
            result = try std.fs.path.join(allocator, &[_][]const u8{ self.build_dir, result });
        }
        result = try std.fs.path.relative(allocator, self.project_root, result);

        // Determine if we care about nodes from this file.
        var in_scope = true;
        if (std.mem.startsWith(u8, result, "../")) {
            in_scope = false;
        } else {
            for (self.third_party_paths_in_project_root) |third_party_root| {
                if (normalizedPathStartsWith(result, third_party_root)) {
                    in_scope = false;
                    break;
                }
            }
        }
        if (!in_scope) {
            result = "";
        }
        return result;
    }
};
// supply these:
allocator: Allocator,
config: Config,

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
    return .{
        .finder = self,
        .it = self.strings.dedup_table.keyIterator(),
    };
}
pub const Iterator = struct {
    finder: *const UnusedFinder,
    it: @TypeOf(@as(StringPool, undefined).dedup_table).KeyIterator,
    pub fn next(self: *@This()) ?Record {
        const loc_i = self.it.next() orelse return null;
        return .{
            .loc = self.finder.strings.getString(loc_i.*),
            .is_used = self.finder.used_locs.contains(loc_i.*),
        };
    }
};
pub const Record = struct {
    loc: []const u8,
    is_used: bool,
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
        if (self.id_to_loc.get(previous_id)) |previous_loc_i| {
            loc_i = previous_loc_i;
        } else {
            // Sometimes clang emits completely bogus dead pointers. Not even defined later.
            // Just ignore them.
        }
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

        var file = try self.config.resolvePath(allocator, node.file);

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
