const std = @import("std");

const UnusedFinder = @import("./UnusedFinder.zig");
const ClangAstScanner = @import("./ClangAstScanner.zig");

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
    while (it.next()) |record| {
        std.debug.print("{} {s}\n", .{
            @boolToInt(record.is_used),
            record.loc,
        });
    }
}
