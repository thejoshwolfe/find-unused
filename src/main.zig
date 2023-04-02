const std = @import("std");
const StreamingParser = std.json.StreamingParser;
const Token = std.json.Token;

pub fn main() !void {
    var input_file = try std.fs.openFileAbsolute("/home/josh/tmp/ast.json", .{});
    const input = input_file.reader();

    var finder = UnusedFinder{
        .project_root = "/home/josh/dev/prometheus-cpp",
        .effective_cwd = "/home/josh/dev/prometheus-cpp/build",
    };
    var scanner = ClangAstScanner{ .downstream = &finder };
    scanner.consume(input) catch |err| {
        std.debug.print("line,col: {},{}\n", .{ scanner.line_number, scanner.column_number });
        return err;
    };
}

const buffer_size = 0x100_000;
const min_unit_size = 0x10_000;

const State = enum {
    outside_node,
    node,
    node_id,
    node_kind,

    node_loc,
    node_loc_file,
    node_loc_line,
    node_loc_col,

    node_is_used,

    ignore, // uses .ignore_depth and .next_state
    expect_object, // uses .next_state

    inner,
};

/// Clang AST Node
const Node = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    file: []const u8 = "",
    line: []const u8 = "",
    col: []const u8 = "",
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

    node: Node = .{},
    node_count: u32 = 0,

    tokenizer: StreamingParser = StreamingParser.init(),
    buffer: [buffer_size]u8 = undefined,

    fn consume(self: *@This(), input: anytype) !void {
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
                            self.state = .node_id;
                        } else if (std.mem.eql(u8, key, "kind")) {
                            self.state = .node_kind;
                        } else if (std.mem.eql(u8, key, "loc")) {
                            self.expectObject(.node_loc);
                        } else if (std.mem.eql(u8, key, "isUsed")) {
                            self.state = .node_is_used;
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

            .node_id => {
                self.node.id = try self.expectSlice(token);
                self.state = .node;
            },
            .node_kind => {
                self.node.kind = try self.expectSlice(token);
                self.state = .node;
            },
            .node_is_used => {
                self.node.is_used = try self.expectBool(token);
                self.state = .node;
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
                            self.state = .node_loc_file;
                        } else if (std.mem.eql(u8, key, "line")) {
                            self.state = .node_loc_line;
                        } else if (std.mem.eql(u8, key, "col")) {
                            self.state = .node_loc_col;
                        } else {
                            self.ignoreValue();
                        }
                    },
                    else => unreachable,
                }
            },
            .node_loc_file => {
                self.node.file = try self.expectSlice(token);
                self.state = .node_loc;
            },
            .node_loc_line => {
                self.node.line = try self.expectSlice(token);
                self.state = .node_loc;
            },
            .node_loc_col => {
                self.node.col = try self.expectSlice(token);
                self.state = .node_loc;
            },

            .expect_object => {
                if (token != .ObjectBegin) return error.ExpectedObject;
                self.nextState();
            },
            .ignore => {
                switch (token) {
                    .ObjectBegin, .ArrayBegin => {
                        self.ignore_depth += 1;
                    },
                    .ObjectEnd, .ArrayEnd => {
                        if (self.ignore_depth <= 1) {
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
    fn nextState(self: *@This()) void {
        self.state = self.next_state;
        self.next_state = undefined;
        self.ignore_depth = undefined;
    }

    fn flushNode(self: *@This()) !void {
        try self.downstream.handleNode(self.node);
        self.node = .{};
        self.node_count += 1;
    }

    fn expectSlice(self: *const @This(), token: Token) ![]const u8 {
        switch (token) {
            .String => |string_token| return self.tokenSlice(string_token),
            .Number => |number_token| return self.tokenSlice(number_token),
            else => return error.ExpectedStringOrNumber,
        }
    }
    fn tokenSlice(self: *const @This(), string_or_number_token: anytype) []const u8 {
        return string_or_number_token.slice(self.buffer[0..], self.read_cursor - 1);
    }

    fn expectBool(self: *const @This(), token: Token) !bool {
        _ = self;
        switch (token) {
            .True => return true,
            .False => return false,
            else => return error.ExpectedBool,
        }
    }
};

const kinds_of_interest = std.ComptimeStringMap(void, .{
    .{"CXXMethodDecl"},
    .{"FunctionDecl"},
    .{"CXXConstructorDecl"},
    .{"CXXConversionDecl"},
});

const UnusedFinder = struct {
    project_root: []const u8,
    effective_cwd: []const u8,

    _current_file_buf: [4096]u8 = undefined,
    current_file: []const u8 = "",
    _current_line_buf: [16]u8 = undefined,
    current_line: []const u8 = "",
    fn handleNode(self: *@This(), node: Node) !void {
        // We need to record the current source position, because it might be omitted from later nodes.
        try self.recordLocInfo(node);

        if (!kinds_of_interest.has(node.kind)) return;

        const col = node.col;

        if (self.current_file.len == 0 or self.current_line.len == 0 or col.len == 0) {
            // Nodes without loc info are out of scope for this analysis.
            // e.g. compiler builtins.
            return;
        }

        var buf: [0x1000]u8 = undefined;
        var fixed_stream = std.io.fixedBufferStream(&buf);
        var out = fixed_stream.writer();
        try std.fmt.format(out, "{} {s}:{s}:{s}\n", .{
            @boolToInt(node.is_used),
            self.current_file,
            self.current_line,
            node.col,
        });
        try std.io.getStdOut().writer().writeAll(fixed_stream.getWritten());
    }

    fn recordLocInfo(self: *@This(), node: Node) !void {
        if (node.file.len > 0) {
            // Resolve the path to the canonical form that we want.
            var buf: [0x2000]u8 = undefined;
            var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&buf);
            var allocator = fixed_buffer_allocator.allocator();

            var file = node.file;
            if (!std.fs.path.isAbsolute(file)) {
                file = try std.fs.path.join(allocator, &[_][]const u8{self.effective_cwd, file});
            }
            file = try std.fs.path.relative(allocator, self.project_root, file);

            // Determine if we care about nodes from this file.
            var in_scope: bool = undefined;
            if (std.mem.startsWith(u8, file, "../")) {
                in_scope = false;
            } else {
                // TODO: exclude vendored dependencies here.
                in_scope = true;
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
