const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const StreamingParser = std.json.StreamingParser;
const Token = std.json.Token;
const StringPool = @import("./StringPool.zig");

pub fn main() !void {
    var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (_gpa.deinit()) {
            std.debug.print("WARNING: memory leaks\n", .{});
        }
    }
    const gpa = _gpa.allocator();

    var input_file = try std.fs.openFileAbsolute("/home/josh/tmp/ast.json", .{});
    defer input_file.close();
    const input = input_file.reader();

    var finder = UnusedFinder{
        .allocator = gpa,
        .project_root = "/home/josh/dev/prometheus-cpp",
        .effective_cwd = "/home/josh/dev/prometheus-cpp/build",
        .third_party_paths_in_project_root = &[_][]const u8{
            "3rdparty/civetweb",
            "3rdparty/googletest",
        },
    };
    defer finder.deinit();

    var scanner = ClangAstScanner{ .downstream = &finder };
    scanner.consume(input) catch |err| {
        std.debug.print("line,col: {},{}\n", .{ scanner.line_number, scanner.column_number });
        return err;
    };

    // Report some stuff.
    var it = finder.iterator();
    while (it.next()) |loc_i| {
        const is_used = finder.used_locs.contains(loc_i);
        const loc_str = finder.strings.getString(loc_i);

        std.debug.print("{} {s}\n", .{
            @boolToInt(is_used),
            loc_str,
        });
    }
}

const buffer_size = 0x100_000;
const min_unit_size = 0x10_000;

const State = enum {
    outside_node,
    node,
    node_loc,

    ignore, // uses .ignore_depth and .next_state
    expect_object, // uses .next_state
    expect_bool, // uses .dest_field_bool and .next_state
    expect_slice, // uses .dest_field_slice and .next_state

    inner,
};

/// Clang AST Node
const Node = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    file: []const u8 = "",
    line: []const u8 = "",
    col: []const u8 = "",
    previous_decl: []const u8 = "",
    is_implicit: bool = false,
    is_used: bool = false,
};

const ClangAstScanner = struct {
    downstream: *UnusedFinder,

    write_cursor: u32 = 0,
    read_cursor: u32 = 0,
    input_at_eof: bool = false,
    ever_got_input: bool = false,
    line_number: u32 = 1,
    column_number: u32 = 1,

    state: State = .outside_node,
    next_state: State = undefined,
    ignore_depth: u8 = undefined,
    dest_field_bool: *bool = undefined,
    dest_field_slice: *[]const u8 = undefined,

    node: Node = .{},
    node_count: u32 = 0,

    tokenizer: StreamingParser = StreamingParser.init(),
    buffer: [buffer_size]u8 = undefined,

    pub fn consume(self: *@This(), input: anytype) !void {
        while (true) {
            if (self.write_cursor - self.read_cursor < min_unit_size and self.state == .outside_node) {
                // Not enough buffered.
                if (!self.input_at_eof) {
                    try self.refill(input);
                    if (self.input_at_eof and !self.ever_got_input) {
                        // 0-byte input.
                        return error.UnexpectedEndOfInput;
                    }
                } else {
                    // Coming up on the end.
                    if (self.write_cursor == self.read_cursor) {
                        // The end.
                        if (!self.tokenizer.complete) return error.UnexpectedEndOfInput;
                        break;
                    }
                }
            } else if (self.read_cursor >= self.write_cursor) {
                return error.NodeTooBig;
            }

            // Consume 1 byte.
            var token: ?Token = undefined;
            var second_token: ?Token = undefined;
            const c = self.buffer[self.read_cursor];
            defer {
                if (c == '\n') {
                    self.line_number += 1;
                    self.column_number = 1;
                } else {
                    self.column_number += 1;
                }
            }
            try self.tokenizer.feed(c, &token, &second_token);
            self.read_cursor += 1;
            if (token) |t| {
                try self.handleToken(t);
            } else {
                continue;
            }
            if (second_token) |t| try self.handleToken(t);
        }
    }

    fn refill(self: *@This(), input: anytype) !void {
        // Retain anything still in the buffer.
        if (self.read_cursor > 0) {
            std.mem.copyBackwards(u8, self.buffer[0..], self.buffer[self.read_cursor..self.write_cursor]);
            self.write_cursor -= self.read_cursor;
            self.read_cursor = 0;
        }

        while (self.write_cursor < buffer_size - min_unit_size) {
            const written = try input.read(self.buffer[self.write_cursor..]);
            if (written == 0) {
                self.input_at_eof = true;
                break;
            } else {
                self.ever_got_input = true;
                self.write_cursor += @intCast(u32, written);
            }
        }
    }

    fn handleToken(self: *@This(), token: Token) !void {
        switch (self.state) {
            .outside_node => {
                switch (token) {
                    .ObjectBegin => {
                        self.state = .node;
                    },
                    .ArrayEnd, .ObjectEnd => {
                        // Exiting an "inner" group.
                    },
                    else => return error.ExpectedNode,
                }
            },
            .node => {
                switch (token) {
                    .ObjectEnd => {
                        try self.flushNode();
                        self.state = .outside_node;
                    },
                    .String => |string_token| {
                        if (string_token.escapes != .None) return error.UnsupportedObjectKeyEscapes;
                        const key = self.tokenSlice(string_token);

                        if (std.mem.eql(u8, key, "id")) {
                            self.expectSlice(&self.node.id);
                        } else if (std.mem.eql(u8, key, "kind")) {
                            self.expectSlice(&self.node.kind);
                        } else if (std.mem.eql(u8, key, "loc")) {
                            self.expectObject(.node_loc);
                        } else if (std.mem.eql(u8, key, "isUsed")) {
                            self.expectBool(&self.node.is_used);
                        } else if (std.mem.eql(u8, key, "isImplicit")) {
                            self.expectBool(&self.node.is_implicit);
                        } else if (std.mem.eql(u8, key, "previousDecl")) {
                            self.expectSlice(&self.node.previous_decl);
                        } else if (std.mem.eql(u8, key, "inner")) {
                            // "inner" is *always* the last property (if present), so we can correctly flush now.
                            try self.flushNode();
                            self.state = .inner;
                        } else {
                            self.ignoreValue();
                        }
                    },
                    else => unreachable,
                }
            },

            .node_loc => {
                switch (token) {
                    .ObjectEnd => {
                        self.state = .node;
                    },
                    .String => |string_token| {
                        if (string_token.escapes != .None) return error.UnsupportedObjectKeyEscapes;
                        const key = self.tokenSlice(string_token);

                        if (std.mem.eql(u8, key, "file")) {
                            self.expectSlice(&self.node.file);
                        } else if (std.mem.eql(u8, key, "line")) {
                            self.expectSlice(&self.node.line);
                        } else if (std.mem.eql(u8, key, "col")) {
                            self.expectSlice(&self.node.col);
                        } else {
                            self.ignoreValue();
                        }
                    },
                    else => unreachable,
                }
            },

            .expect_object => {
                if (token != .ObjectBegin) return error.ExpectedObject;
                self.nextState();
            },
            .expect_bool => {
                switch (token) {
                    .True => self.dest_field_bool.* = true,
                    .False => self.dest_field_bool.* = false,
                    else => return error.ExpectedBool,
                }
                self.nextState();
            },
            .expect_slice => {
                switch (token) {
                    .String => |string_token| self.dest_field_slice.* = self.tokenSlice(string_token),
                    .Number => |number_token| self.dest_field_slice.* = self.tokenSlice(number_token),
                    else => return error.ExpectedStringOrNumber,
                }
                self.nextState();
            },

            .ignore => {
                switch (token) {
                    .ObjectBegin, .ArrayBegin => {
                        self.ignore_depth += 1;
                    },
                    .ObjectEnd, .ArrayEnd => {
                        if (self.ignore_depth <= 1) {
                            // Finally done.
                            self.nextState();
                        } else {
                            self.ignore_depth -= 1;
                        }
                    },
                    else => {
                        if (self.ignore_depth == 0) {
                            // The ignored value was a primitive.
                            self.nextState();
                        }
                    },
                }
            },

            .inner => {
                // This is expectArray()
                if (token != .ArrayBegin) return error.ExpectedArray;
                self.state = .outside_node;
            },
        }
    }

    fn ignoreValue(self: *@This()) void {
        self.next_state = self.state;
        self.state = .ignore;
        self.ignore_depth = 0;
    }

    fn expectObject(self: *@This(), next_state: State) void {
        self.next_state = next_state;
        self.state = .expect_object;
    }
    fn expectBool(self: *@This(), dest_field: *bool) void {
        self.next_state = self.state;
        self.state = .expect_bool;
        self.dest_field_bool = dest_field;
    }
    fn expectSlice(self: *@This(), dest_field: *[]const u8) void {
        self.next_state = self.state;
        self.state = .expect_slice;
        self.dest_field_slice = dest_field;
    }
    fn nextState(self: *@This()) void {
        self.state = self.next_state;
        self.next_state = undefined;
        self.ignore_depth = undefined;
        self.dest_field_bool = undefined;
    }

    fn flushNode(self: *@This()) !void {
        try self.downstream.handleNode(self.node);
        self.node = .{};
        self.node_count += 1;
    }

    fn tokenSlice(self: *const @This(), string_or_number_token: anytype) []const u8 {
        return string_or_number_token.slice(self.buffer[0..], self.read_cursor - 1);
    }
};

const kinds_of_interest = std.ComptimeStringMap(void, .{
    .{"FunctionDecl"},
    .{"CXXMethodDecl"},
    .{"CXXConstructorDecl"},
    .{"CXXConversionDecl"},
    // (It's hard to imagine a scenario when it's useful to know that a destructor is unused.)
});

const UnusedFinder = struct {

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
    _current_file_buf: [4096]u8 = undefined,
    current_file: []const u8 = "",
    _current_line_buf: [16]u8 = undefined,
    current_line: []const u8 = "",

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
        fn next(self: *@This()) ?u32 {
            return (self.it.next() orelse return null).*;
        }
    };

    pub fn handleNode(self: *@This(), node: Node) !void {
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

    fn recordLocInfo(self: *@This(), node: Node) !void {
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
            try self.saveStr(file, &self._current_file_buf, &self.current_file);
        }

        if (self.current_file.len > 0 and node.line.len > 0) {
            try self.saveStr(node.line, &self._current_line_buf, &self.current_line);
        }
    }
    fn saveStr(_: *const @This(), src: []const u8, buf: anytype, dest_slice: *[]const u8) !void {
        if (src.len > buf.len) return error.StringTooLong;
        std.mem.copy(u8, buf, src);
        dest_slice.* = buf[0..src.len];
    }
};

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
