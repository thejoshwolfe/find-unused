const std = @import("std");
const StreamingParser = std.json.StreamingParser;
const Token = std.json.Token;

pub fn main() !void {
    var input_file = try std.fs.openFileAbsolute("/home/josh/tmp/ast.json", .{});
    const input = input_file.reader();

    var scanner = ClangAstScanner{};
    scanner.consume(input) catch |err| {
        std.debug.print("line,col: {},{}\n", .{ scanner.line_number, scanner.column_number });
        return err;
    };

    std.debug.print("Done.\n", .{});
}

const buffer_size = 0x100_000;
const min_unit_size = 0x10_000;

const State = union(enum) {
    outside_node,
    inside_node,
    node_id,
    node_kind,
    //node_loc,
    //node_loc_file,
    //node_loc_line,
    //node_loc_col,

    node_ignore: u8,

    inner,
};

/// Clang AST Node
const Node = struct {
    id: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    //file: ?[]const u8 = null,
    //line: ?[]const u8 = null,
    //col: ?[]const u8 = null,
    //is_used: bool = false,
};

const ClangAstScanner = struct {
    write_cursor: u32 = 0,
    read_cursor: u32 = 0,
    input_at_eof: bool = false,
    ever_got_input: bool = false,
    line_number: u32 = 1,
    column_number: u32 = 1,

    state: State = .outside_node,

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
                        self.state = .inside_node;
                    },
                    .ArrayEnd, .ObjectEnd => {
                        // Exiting an "inner" group.
                    },
                    else => return error.ExpectedNode,
                }
            },
            .inside_node => {
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
                        } else if (std.mem.eql(u8, key, "inner")) {
                            // "inner" is *always* the last property (if present), so we can correctly flush now.
                            try self.flushNode();
                            self.state = .inner;
                        } else {
                            self.state = .{ .node_ignore = 0 };
                        }
                    },
                    else => unreachable,
                }
            },

            .node_id => {
                self.node.id = try self.expectSlice(token);
                self.state = .inside_node;
            },
            .node_kind => {
                self.node.kind = try self.expectSlice(token);
                self.state = .inside_node;
            },

            .node_ignore => |depth| {
                switch (token) {
                    .ObjectBegin, .ArrayBegin => {
                        self.state = .{ .node_ignore = depth + 1 };
                    },
                    .ObjectEnd, .ArrayEnd => {
                        if (depth <= 1) {
                            self.state = .inside_node;
                        } else {
                            self.state = .{ .node_ignore = depth - 1 };
                        }
                    },
                    else => {
                        if (depth == 0) {
                            // The ignored value was a primitive.
                            self.state = .inside_node;
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

    fn flushNode(self: *@This()) !void {
        self.node = .{};
        self.node_count += 1;
        std.debug.print("\r{}", .{self.node_count});
    }

    fn expectSlice(self: @This(), token: Token) ![]const u8 {
        switch (token) {
            .String => |string_token| return self.tokenSlice(string_token),
            .Number => |number_token| return self.tokenSlice(number_token),
            else => return error.ExpectedStringOrNumber,
        }
    }
    fn tokenSlice(self: @This(), string_or_number_token: anytype) []const u8 {
        return string_or_number_token.slice(self.buffer[0..], self.read_cursor - 1);
    }
};
