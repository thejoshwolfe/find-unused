//! TODO: the "documentation" for the json "schema" is here: JSONNodeDumper.cpp
//! Audit that to see if there's anything we care about.
const std = @import("std");
const StreamingParser = std.json.StreamingParser;
const Token = std.json.Token;

const UnusedFinder = @import("./UnusedFinder.zig");
const ClangAstNode = @import("./ClangAstNode.zig");

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

node: ClangAstNode = .{},

tokenizer: StreamingParser = StreamingParser.init(),
input_buffer: [buffer_size]u8 = undefined,

node_arena: std.heap.ArenaAllocator,

/// Only matters for performance.
const buffer_size = 0x10_000;
/// This is the limit on how long a string value can be.
/// Also, the smaller it is, the better the performance.
const min_unit_size = 0x1_000;

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

pub fn consume(self: *@This(), input: anytype) !void {
    while (true) {
        if (self.write_cursor - self.read_cursor < min_unit_size and self.isSafeToMoveBuffer()) {
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
            return error.ValueTooLong;
        }

        // Take 1 byte.
        const c = self.input_buffer[self.read_cursor];
        self.read_cursor += 1;
        if (c == '\n') {
            self.line_number += 1;
            self.column_number = 1;
        } else {
            self.column_number += 1;
        }

        // Consume the delicious byte.
        var token: ?Token = undefined;
        var second_token: ?Token = undefined;
        try self.tokenizer.feed(c, &token, &second_token);
        if (token) |t| {
            try self.handleToken(t);
            if (second_token) |t2| {
                try self.handleToken(t2);
            }
        }
    }
}

fn refill(self: *@This(), input: anytype) !void {
    // Retain anything still in the input_buffer.
    if (self.read_cursor > 0) {
        std.mem.copyBackwards(u8, self.input_buffer[0..], self.input_buffer[self.read_cursor..self.write_cursor]);
        self.write_cursor -= self.read_cursor;
        self.read_cursor = 0;
    }

    while (self.write_cursor < buffer_size - min_unit_size) {
        const written = try input.read(self.input_buffer[self.write_cursor..]);
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
                    } else if (std.mem.eql(u8, key, "explicitlyDeleted")) {
                        self.expectBool(&self.node.is_explicitly_deleted);
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
                .String => |string_token| self.dest_field_slice.* = try self.node_arena.allocator().dupe(u8, self.tokenSlice(string_token)),
                .Number => |number_token| self.dest_field_slice.* = try self.node_arena.allocator().dupe(u8, self.tokenSlice(number_token)),
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
    self.dest_field_slice = undefined;
}

fn flushNode(self: *@This()) !void {
    try self.downstream.handleNode(self.node);

    self.node = .{};
    _ = self.node_arena.reset(.retain_capacity);
}

fn tokenSlice(self: *const @This(), string_or_number_token: anytype) []const u8 {
    return string_or_number_token.slice(self.input_buffer[0..], self.read_cursor - 1);
}

fn isSafeToMoveBuffer(self: *const @This()) bool {
    return switch (self.tokenizer.state) {
        .ObjectSeparator,
        .ValueEnd,
        .TopLevelBegin,
        .TopLevelEnd,
        .ValueBegin,
        .ValueBeginNoClosing,
        => true,

        .String,
        .StringUtf8Byte2Of2,
        .StringUtf8Byte2Of3,
        .StringUtf8Byte3Of3,
        .StringUtf8Byte2Of4,
        .StringUtf8Byte3Of4,
        .StringUtf8Byte4Of4,
        .StringEscapeCharacter,
        .StringEscapeHexUnicode4,
        .StringEscapeHexUnicode3,
        .StringEscapeHexUnicode2,
        .StringEscapeHexUnicode1,
        => false,

        .Number,
        .NumberMaybeDotOrExponent,
        .NumberMaybeDigitOrDotOrExponent,
        .NumberFractionalRequired,
        .NumberFractional,
        .NumberMaybeExponent,
        .NumberExponent,
        .NumberExponentDigitsRequired,
        .NumberExponentDigits,
        => false,

        .TrueLiteral1,
        .TrueLiteral2,
        .TrueLiteral3,
        .FalseLiteral1,
        .FalseLiteral2,
        .FalseLiteral3,
        .FalseLiteral4,
        .NullLiteral1,
        .NullLiteral2,
        .NullLiteral3,
        => true,
    };
}
