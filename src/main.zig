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

    var clang_cmd = std.ArrayList([]const u8).init(gpa);
    defer clang_cmd.deinit();

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        try clang_cmd.append(arg);
    }
    try clang_cmd.appendSlice(&[_][]const u8{
        "-Wno-everything",
        "-Xclang",
        "-ast-dump=json",
    });

    var clang = std.ChildProcess.init(clang_cmd.items, gpa);

    clang.stdout_behavior = .Pipe;
    try clang.spawn();

    const input = clang.stdout.?.reader();

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

    switch (try clang.wait()) {
        .Exited => |code| if (code != 0) return error.ChildProcessError,
        else => return error.ChildProcessError,
    }

    // Report some stuff.
    var it = finder.iterator();
    while (it.next()) |record| {
        std.debug.print("{} {s}\n", .{
            @boolToInt(record.is_used),
            record.loc,
        });
    }
}
