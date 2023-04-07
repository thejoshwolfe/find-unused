const std = @import("std");

const UnusedFinder = @import("./UnusedFinder.zig");
const ClangAstScanner = @import("./ClangAstScanner.zig");
const parseClangCli = @import("./clang_cli_parser.zig").parseClangCli;

pub fn main() !void {
    var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (_gpa.deinit()) {
            std.debug.print("WARNING: memory leaks\n", .{});
        }
    }
    const gpa = _gpa.allocator();

    var _config_arena = std.heap.ArenaAllocator.init(gpa);
    defer _config_arena.deinit();
    const config_arena = _config_arena.allocator();

    const cwd = try std.fs.realpathAlloc(config_arena, ".");
    var config = UnusedFinder.Config{
        .project_root = cwd,
        .build_dir = cwd,
    };
    var exclude_list = std.ArrayList([]const u8).init(config_arena);

    var args = std.process.args();
    self_path = args.next() orelse printUsage("empty argv");
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            break;
        } else if (std.mem.eql(u8, arg, "--project")) {
            config.project_root = try normalize(config_arena, args.next() orelse printUsage("expected arg after --project"));
        } else if (std.mem.eql(u8, arg, "--build-dir")) {
            config.build_dir = try normalize(config_arena, args.next() orelse printUsage("expected arg after --build-dir"));
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            try exclude_list.append(args.next() orelse printUsage("expected arg after --exclude"));
        } else {
            printUsage("unrecognized argument");
        }
    } else {
        printUsage("expected '--'");
    }

    const exclude_array = try config_arena.alloc([]const u8, exclude_list.items.len);
    for (exclude_list.items, exclude_array) |item, *out_item| {
        out_item.* = try std.fs.path.relative(config_arena, config.project_root, item);
    }
    config.third_party_paths_in_project_root = exclude_array;

    var clang_cmd = std.ArrayList([]const u8).init(gpa);
    defer clang_cmd.deinit();

    while (args.next()) |arg| {
        try clang_cmd.append(arg);
    }
    const clang_parameters = parseClangCli(clang_cmd.items) orelse printUsage("expected clang compile command after '--'");
    if (!clang_parameters.is_compile) printUsage("clang command isn't a compile command?");

    if ((try config.resolvePath(config_arena, clang_parameters.source_file)).len == 0) printUsage("source file is out of scope");
    const _output_file = try std.fs.path.join(config_arena, &[_][]const u8{ config.build_dir, clang_parameters.output_file });
    const cache_file = try std.mem.concat(config_arena, u8, &[_][]const u8{ _output_file, ".cache" });
    const cache_file_tmp = try std.mem.concat(config_arena, u8, &[_][]const u8{ cache_file, ".tmp" });

    try clang_cmd.appendSlice(&[_][]const u8{
        "-Wno-everything",
        "-Xclang",
        "-ast-dump=json",
    });
    var clang = std.ChildProcess.init(clang_cmd.items, gpa);
    clang.stdout_behavior = .Pipe;
    clang.cwd = config.build_dir;
    try clang.spawn();
    const input = clang.stdout.?.reader();

    var finder = UnusedFinder{
        .allocator = gpa,
        .config = config,
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
    {
        var output_file = try std.fs.createFileAbsolute(cache_file_tmp, .{});
        defer output_file.close();
        const writer = output_file.writer();
        var it = finder.iterator();
        while (it.next()) |record| {
            try writer.print("{} {s}\n", .{
                @boolToInt(record.is_used),
                record.loc,
            });
        }
    }
    try std.os.rename(cache_file_tmp, cache_file);
}

fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, path);
}

var self_path: []const u8 = "<self>";
fn printUsage(msg: []const u8) noreturn {
    std.io.getStdOut().writer().print(
        \\error: {s}
        \\
        \\usage: {s} [options...] -- clang-cmd...
        \\
        \\options:
        \\  --project <dir>    Default is '.'.
        \\  --build-dir <dir>  Default is '.'.
        \\  --exclude <dir>    Can be specified multiple times.
        \\
    , .{ msg, self_path }) catch {};
    std.process.exit(2);
}
