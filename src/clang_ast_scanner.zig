//! TODO: the "documentation" for the json "schema" is here: JSONNodeDumper.cpp
//! Audit that to see if there's anything we care about.
const std = @import("std");
const Allocator = std.mem.Allocator;

const JsonReader = std.json.Reader;
const default_buffer_size = std.json.default_buffer_size;
const Token = std.json.Token;
const Diagnostics = std.json.Diagnostics;
const AllocWhen = std.json.AllocWhen;

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
                    try self.parseLocation(&node.location, &node.secondary_locaction, true);
                } else if (std.mem.eql(u8, key, "isUsed")) {
                    node.is_used = try self.nextBool();
                } else if (std.mem.eql(u8, key, "isImplicit")) {
                    node.is_implicit = try self.nextBool();
                } else if (std.mem.eql(u8, key, "explicitlyDeleted")) {
                    node.is_explicitly_deleted = try self.nextBool();
                } else if (std.mem.eql(u8, key, "previousDecl")) {
                    node.previous_decl = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "mangledName")) {
                    node.mangled_name = try self.nextSlice(.alloc_always);
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

        fn parseLocation(self: *@This(), out_location: *ClangAstNode.Location, out_secondary_location: *ClangAstNode.Location, comptime allow_recursion: bool) !void {
            if (.object_begin != try self.json_reader.next()) return error.UnexpectedToken;
            while (try self.stillInObject()) {
                if (.object_end == try self.json_reader.peekNextTokenType()) {
                    _ = try self.json_reader.next();
                    break;
                }
                var key = try self.nextSlice(.alloc_if_needed);
                if (std.mem.eql(u8, key, "file")) {
                    out_location.file = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "line")) {
                    out_location.line = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "presumedFile")) {
                    out_location.presumed_file = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "presumedLine")) {
                    out_location.presumed_line = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "col")) {
                    out_location.col = try self.nextSlice(.alloc_always);
                } else if (std.mem.eql(u8, key, "expansionLoc")) {
                    if (!allow_recursion) return error.UnexpectedToken;
                    // The expansion loc is where the compiler's "cursor" is, so it's the primary one.
                    try self.parseLocation(out_location, undefined, false);
                } else if (std.mem.eql(u8, key, "spellingLoc")) {
                    if (!allow_recursion) return error.UnexpectedToken;
                    // The spelling loc is where the macro is defined.
                    try self.parseLocation(out_secondary_location, undefined, false);
                } else {
                    try self.json_reader.skipValue();
                }
            }
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
