//! TODO: the "documentation" for the json "schema" is here: JSONNodeDumper.cpp
//! Audit that to see if there's anything we care about.
const std = @import("std");
const Allocator = std.mem.Allocator;

const JsonReader = @import("./json.zig").JsonReader;
const default_buffer_size = @import("./json.zig").default_buffer_size;
const Token = @import("./json.zig").Token;
const Diagnostics = @import("./json.zig").Diagnostics;
const AllocWhen = @import("./json.zig").AllocWhen;

const ClangAstNode = @import("./ClangAstNode.zig");

pub fn clangAstScanner(allocator: Allocator, reader: anytype) ClangAstScanner(@TypeOf(reader)) {
    return ClangAstScanner(@TypeOf(reader)).init(allocator, reader);
}
pub fn ClangAstScanner(comptime Reader: type) type {
    return struct {
        json_reader: JsonReader(default_buffer_size, Reader),
        node_arena: std.heap.ArenaAllocator,

        pub fn init(allocator: Allocator, input: Reader) @This() {
            return .{
                .json_reader = JsonReader(default_buffer_size, Reader).init(allocator, input),
                .node_arena = std.heap.ArenaAllocator.init(allocator),
            };
        }
        pub fn deinit(self: *@This()) void {
            self.node_arena.deinit();
            self.json_reader.deinit();
            self.* = undefined;
        }
        pub fn enableDiagnostics(self: *@This(), diagnostics: *Diagnostics) void {
            self.json_reader.enableDiagnostics(diagnostics);
        }

        pub fn next(self: *@This()) !?ClangAstNode {
            _ = self.node_arena.reset(.retain_capacity);

            // Find the beginning of a node.
            while (true) {
                switch (try self.json_reader.next()) {
                    .object_end, .array_end => continue, // Get out of any "inner" field.
                    .object_begin => break, // This is the start of a node.
                    .end_of_document => return null, // Done with everything.
                    else => return error.UnexpectedToken,
                }
            }

            var node: ClangAstNode = .{};
            while (try self.stillInObject()) {
                var key = try self.nextSlice(.alloc_if_needed);

                if (std.mem.eql(u8, key, "id")) {
                    node.id = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "kind")) {
                    node.kind = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "loc")) {
                    if (.object_begin != try self.json_reader.next()) return error.UnexpectedToken;
                    while (try self.stillInObject()) {
                        if (.object_end == try self.json_reader.peekNextTokenType()) {
                            _ = try self.json_reader.next();
                            break;
                        }
                        key = try self.nextSlice(.alloc_if_needed);
                        if (std.mem.eql(u8, key, "file")) {
                            node.file = try self.nextSlice(.alloc_always);
                        } else if (std.mem.eql(u8, key, "line")) {
                            node.line = try self.nextSlice(.alloc_always);
                        } else if (std.mem.eql(u8, key, "col")) {
                            node.col = try self.nextSlice(.alloc_always);
                        } else {
                            try self.json_reader.skipValue();
                        }
                    }
                } else if (std.mem.eql(u8, key, "isUsed")) {
                    node.is_used = try self.nextBool();
                } else if (std.mem.eql(u8, key, "isImplicit")) {
                    node.is_implicit = try self.nextBool();
                } else if (std.mem.eql(u8, key, "explicitlyDeleted")) {
                    node.is_explicitly_deleted = try self.nextBool();
                } else if (std.mem.eql(u8, key, "previousDecl")) {
                    node.previous_decl = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "inner")) {
                    // "inner" is *always* the last property (if present), so we can correctly be done now.
                    // Jump into the array so we find a node next.
                    if (.array_begin != try self.json_reader.next()) return error.UnexpectedToken;
                    return node;
                } else {
                    // Ingore fields we don't care about.
                    try self.json_reader.skipValue();
                }
            }

            return node;
        }

        fn nextSlice(self: *@This(), alloc_when: AllocWhen) ![]const u8 {
            switch (try self.json_reader.nextAlloc(self.node_arena.allocator(), alloc_when)) {
                .number, .string => |slice| return slice,
                .allocated_number, .allocated_string => |slice| return slice,
                else => return error.ExpectedSliceValue,
            }
        }
        fn nextBool(self: *@This()) !bool {
            switch (try self.json_reader.next()) {
                .true => return true,
                .false => return false,
                else => return error.ExpectedBoolean,
            }
        }

        fn stillInObject(self: *@This()) !bool {
            switch (try self.json_reader.peekNextTokenType()) {
                .string => return true,
                .object_end => {
                    _ = try self.json_reader.next();
                    return false;
                },
                else => unreachable,
            }
        }
    };
}
