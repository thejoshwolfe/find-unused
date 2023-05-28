const std = @import("std");

const Diagnostics = std.json.Diagnostics;

const UnusedFinder = @import("./UnusedFinder.zig");
const clangAstScanner = @import("./clang_ast_scanner.zig").clangAstScanner;

const parseClangCli = @import("./clang_cli_parser.zig").parseClangCli;
const ClangCommand = @import("./clang_cli_parser.zig").ClangCommand;

const BashParser = @import("./bash_parser.zig").BashParser;
const StringPool = @import("./StringPool.zig");

pub fn main() !void {
    var _gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (_gpa.deinit() != .ok) {
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
    var clang_command_on_cli = false;
    var trust_cache = true;
    var ast_json: ?[]const u8 = null;

    var args = std.process.args();
    self_path = args.next() orelse printUsage("empty argv");
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            if (!clang_command_on_cli) printUsage("specifying a command after '--' requires --clang-cmd");
            break;
        } else if (std.mem.eql(u8, arg, "--project")) {
            config.project_root = try normalize(config_arena, args.next() orelse printUsage("expected arg after --project"));
        } else if (std.mem.eql(u8, arg, "--build-dir")) {
            config.build_dir = try normalize(config_arena, args.next() orelse printUsage("expected arg after --build-dir"));
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            try exclude_list.append(args.next() orelse printUsage("expected arg after --exclude"));
        } else if (std.mem.eql(u8, arg, "--clang-cmd")) {
            if (ast_json != null) printUsage("cannot use both --clang-cmd and --ast-json");
            clang_command_on_cli = true;
        } else if (std.mem.eql(u8, arg, "--ast-json")) {
            if (clang_command_on_cli) printUsage("cannot use both --clang-cmd and --ast-json");
            ast_json = args.next() orelse printUsage("expected arg after --ast-json");
        } else if (std.mem.eql(u8, arg, "--no-trust-cache")) {
            trust_cache = false;
        } else {
            printUsageFmt("unrecognized argument: {s}", .{arg});
        }
    } else {
        if (clang_command_on_cli) printUsage("expected '--' with '--clang-command'");
    }

    const exclude_array = try config_arena.alloc([]const u8, exclude_list.items.len);
    for (exclude_list.items, exclude_array) |item, *out_item| {
        out_item.* = try std.fs.path.relative(config_arena, config.project_root, item);
    }
    config.third_party_paths_in_project_root = exclude_array;

    if (clang_command_on_cli) {
        var clang_cmd = std.ArrayList([]const u8).init(gpa);
        defer clang_cmd.deinit();

        while (args.next()) |arg| {
            try clang_cmd.append(arg);
        }

        const cache_file = try analyzeClangCommand(gpa, config, trust_cache, parseClangCli(clang_cmd.items) orelse {
            printUsage("That's not a clang command.");
        }) orelse {
            printUsage("That clang command is out of scope.");
        };
        defer gpa.free(cache_file);

        try std.io.getStdOut().writer().print("{s}\n", .{cache_file});
    } else if (ast_json) |json_path| {
        const json_file = try std.fs.cwd().openFile(json_path, .{});
        try analyzeAstJson(gpa, config, json_file.reader(), std.io.getStdOut().writer());
    } else {
        try analyzeNinjaProject(gpa, config, trust_cache);
    }
}

fn analyzeClangCommand(gpa: std.mem.Allocator, config: UnusedFinder.Config, trust_cache: bool, clang_command: ClangCommand) !?[]const u8 {
    var _arena = std.heap.ArenaAllocator.init(gpa);
    defer _arena.deinit();
    const arena = _arena.allocator();

    if ((try config.resolvePath(arena, clang_command.source_file)).len == 0) return null;
    const _output_file = try std.fs.path.join(arena, &[_][]const u8{ config.build_dir, clang_command.output_file });
    const cache_file = try std.mem.concat(gpa, u8, &[_][]const u8{ _output_file, ".find-unused-cache" });
    errdefer gpa.free(cache_file);
    if (trust_cache and try isCacheFresh(_output_file, cache_file)) {
        return cache_file;
    }
    const cache_file_tmp = try std.mem.concat(arena, u8, &[_][]const u8{ cache_file, ".tmp" });

    const additional_clang_args = &[_][]const u8{
        "-Wno-everything",
        "-Xclang",
        "-ast-dump=json",
    };
    var ast_dump_cmd = try std.ArrayList([]const u8).initCapacity(arena, clang_command.complete_cmd.len + additional_clang_args.len);
    ast_dump_cmd.appendSliceAssumeCapacity(clang_command.complete_cmd);
    ast_dump_cmd.appendSliceAssumeCapacity(additional_clang_args);
    {
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();
        try std.io.getStdErr().writer().print("Analyzing:", .{});
        for (ast_dump_cmd.items) |arg| {
            try std.io.getStdErr().writer().print(" {s}", .{arg});
        }
        try std.io.getStdErr().writer().print("\n", .{});
    }
    var clang = std.ChildProcess.init(ast_dump_cmd.items, arena);
    clang.stdout_behavior = .Pipe;
    clang.cwd = config.build_dir;
    try clang.spawn();

    {
        var output_file = try std.fs.createFileAbsolute(cache_file_tmp, .{});
        defer output_file.close();

        try analyzeAstJson(gpa, config, clang.stdout.?.reader(), output_file.writer());
    }

    switch (try clang.wait()) {
        .Exited => |code| if (code != 0) return error.ChildProcessError,
        else => return error.ChildProcessError,
    }

    try std.os.rename(cache_file_tmp, cache_file);

    return cache_file;
}

fn analyzeClangCommandIntoArrayList(
    gpa: std.mem.Allocator,
    config: UnusedFinder.Config,
    trust_cache: bool,
    clang_command: ClangCommand,
    cache_files: *std.ArrayList([]const u8),
    i: usize,
    len: usize,
) !void {
    const cache_file = analyzeClangCommand(gpa, config, trust_cache, clang_command) catch |err| {
        std.debug.print("For clang command:", .{});
        for (clang_command.complete_cmd) |arg| {
            std.debug.print(" {s}", .{arg});
        }
        std.debug.print("\n", .{});
        std.debug.print("  source: {s}\n", .{clang_command.source_file});
        std.debug.print("  output: {s}\n", .{clang_command.output_file});
        return err;
    } orelse return;
    errdefer gpa.free(cache_file);
    {
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();
        try std.io.getStdErr().writer().print("[{}/{}] {s}\n", .{ i, len, cache_file });
    }
    try cache_files.append(cache_file);
}
fn analyzeClangCommandVoid(
    gpa: std.mem.Allocator,
    config: UnusedFinder.Config,
    trust_cache: bool,
    clang_command: ClangCommand,
    cache_files: *std.ArrayList([]const u8),
    i: usize,
    len: usize,
    out_err: *?anyerror,
    wg: *std.Thread.WaitGroup,
) void {
    defer wg.finish();
    analyzeClangCommandIntoArrayList(
        gpa,
        config,
        trust_cache,
        clang_command,
        cache_files,
        i,
        len,
    ) catch |err| {
        out_err.* = err;
    };
}

fn analyzeAstJson(gpa: std.mem.Allocator, config: UnusedFinder.Config, input: anytype, output: anytype) !void {
    var finder = UnusedFinder{
        .allocator = gpa,
        .config = config,
    };
    defer finder.deinit();

    var scanner = clangAstScanner(gpa, input);
    defer scanner.deinit();
    var diagnostics = Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);

    while (scanner.next() catch |err| {
        std.debug.print("line,col: {},{}\n", .{ diagnostics.getLine(), diagnostics.getColumn() });
        return err;
    }) |node| {
        try finder.handleNode(node);
    }

    // Report stuff.
    var it = finder.iterator();
    while (it.next()) |record| {
        try output.print("{} {s}\n", .{
            @boolToInt(record.is_used),
            record.loc,
        });
    }
}

fn normalize(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, path);
}

var self_path: []const u8 = "<self>";
fn printUsage(msg: []const u8) noreturn {
    std.io.getStdOut().writer().print(
        \\error: {s}
        \\
        \\usage: {s} [options...] [--clang-cmd -- clang-cmd... | --ast-json <file>]
        \\
        \\options:
        \\  --project <dir>    Default is '.'.
        \\  --build-dir <dir>  Default is '.'.
        \\  --exclude <dir>    Can be specified multiple times.
        \\  --clang-cmd        Give a specific clang cmd after the '--'.
        \\  --trust-cache      Normally cache files are written, but ignored.
        \\                     This option causes the existence of a cache file
        \\                     to skip generating it. (better caching TBD.)
        \\  --ast-json <file>  Give a path to an ast.json file and print the analysis to stdout.
        \\
    , .{ msg, self_path }) catch {};
    std.process.exit(2);
}
fn printUsageFmt(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [0x1000]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    printUsage(msg);
}

fn analyzeNinjaProject(gpa: std.mem.Allocator, config: UnusedFinder.Config, trust_cache: bool) !void {
    var _arena = std.heap.ArenaAllocator.init(gpa);
    defer _arena.deinit();
    const arena = _arena.allocator();

    var ninja = std.ChildProcess.init(&[_][]const u8{ "ninja", "-t", "commands" }, arena);
    ninja.stdout_behavior = .Pipe;
    ninja.cwd = config.build_dir;
    try ninja.spawn();

    var ninja_output = std.ArrayList(u8).init(arena);
    try pump(ninja.stdout.?.reader(), ninja_output.writer());

    switch (try ninja.wait()) {
        .Exited => |code| if (code != 0) return error.ChildProcessError,
        else => return error.ChildProcessError,
    }

    var clang_commands = std.ArrayList(ClangCommand).init(arena);

    // Each line is a separate script.
    // (pretty sure you can't put newlines in the `command =` part of a ninja rule / build edge.)
    var sh_scripts_it = std.mem.tokenize(u8, ninja_output.items, "\n");
    while (sh_scripts_it.next()) |sh_script| {
        analyzeBashScript(arena, sh_script, &clang_commands) catch |err| switch (err) {
            error.UnsupportedBashFeature,
            error.UnsupportedCdBeforeClangCommand,
            error.UnsupportedReservedWord,
            error.UnsupportedHistoryExpansion,
            error.UnsupportedVariableAssignment,
            => {
                std.debug.print("WARNING: unsupported bash script: {s}\n", .{sh_script});
                continue;
            },
            else => return err,
        };
    }

    // Analyze each clang command.
    var cache_files = std.ArrayList([]const u8).init(arena);
    defer {
        for (cache_files.items) |cache_file| {
            gpa.free(cache_file);
        }
    }

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = gpa });
    defer thread_pool.deinit();
    var wg = std.Thread.WaitGroup{};
    var any_err: ?anyerror = null;

    {
        wg.reset();
        defer wg.wait();
        for (clang_commands.items, 0..) |clang_command, i| {
            wg.start();
            try thread_pool.spawn(
                analyzeClangCommandVoid,
                .{
                    gpa,
                    config,
                    trust_cache,
                    clang_command,
                    &cache_files,
                    clang_commands.items.len - i,
                    clang_commands.items.len,
                    &any_err,
                    &wg,
                },
            );
        }
    }
    if (any_err) |err| return err;

    // Aggregate results from the cache files.
    var strings = StringPool{};
    defer strings.deinit(gpa);
    var line = std.ArrayList(u8).init(gpa);
    defer line.deinit();
    var used_locs = std.AutoHashMap(u32, void).init(gpa);
    defer used_locs.deinit();
    for (cache_files.items) |cache_file| {
        const file = try std.fs.openFileAbsolute(cache_file, .{});
        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();
        while (true) {
            reader.readUntilDelimiterArrayList(&line, '\n', 0x1000) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (!(line.items.len > 2 and line.items[1] == ' ')) return error.MalformedCacheFile;
            var is_used = switch (line.items[0]) {
                '0' => false,
                '1' => true,
                else => return error.MalformedCacheFile,
            };
            const loc_i = try strings.putString(gpa, line.items[2..]);
            if (is_used) try used_locs.put(loc_i, {});
        }
    }

    // Sort the output.
    var sorted = try arena.alloc(u32, strings.dedup_table.size);
    {
        var it = strings.dedup_table.keyIterator();
        var i: usize = 0;
        while (it.next()) |loc_i| : (i += 1) {
            sorted[i] = loc_i.*;
        }
        std.sort.sort(u32, sorted, LocSortingContext{ .strings = strings }, LocSortingContext.lessThan);
    }

    var out = std.io.bufferedWriter(std.io.getStdOut().writer());
    for (sorted) |loc_i| {
        const loc = strings.getString(loc_i);
        const is_used = used_locs.contains(loc_i);
        try out.writer().print("{} {s}\n", .{
            @boolToInt(is_used),
            loc,
        });
    }
    try out.flush();
}

fn analyzeBashScript(arena: std.mem.Allocator, bash_script: []const u8, clang_commands: *std.ArrayList(ClangCommand)) !void {
    var parser = BashParser.init(arena, bash_script);
    var unsupported_cd = false;
    var found_clang_command = false;
    while (true) {
        var bash_command = try parser.nextSimpleCommand();
        if (bash_command.words.len == 0) {
            if (bash_command.control_operator == .eof) break;
            continue;
        }
        if (std.mem.eql(u8, bash_command.words[0], "cd")) {
            unsupported_cd = true;
            continue;
        }
        if (parseClangCli(bash_command.words)) |clang_command| {
            try clang_commands.append(clang_command);
            found_clang_command = true;
        }
    }

    if (found_clang_command and unsupported_cd) return error.UnsupportedCdBeforeClangCommand;
}

fn isCacheFresh(output_file: []const u8, cache_file: []const u8) !bool {
    var output_stat = try statFileAbsolute(output_file);
    var cache_stat = statFileAbsolute(cache_file) catch return false;
    return output_stat.mtime < cache_stat.mtime;
}

/// order strings by file, then by line, then by col.
const LocSortingContext = struct {
    strings: StringPool,

    fn lessThan(self: @This(), a_i: u32, b_i: u32) bool {
        const a = self.strings.getString(a_i);
        const b = self.strings.getString(b_i);
        const a_parts = splitLocStr(a);
        const b_parts = splitLocStr(b);

        // file
        switch (std.mem.order(u8, a_parts[0], b_parts[0])) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        // line
        switch (orderNormalizedUnsignedNumericStr(a_parts[1], b_parts[1])) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        // col
        switch (orderNormalizedUnsignedNumericStr(a_parts[2], b_parts[2])) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return false; // equal
    }

    fn splitLocStr(loc: []const u8) [3][]const u8 {
        const pos_2 = std.mem.lastIndexOfScalar(u8, loc, ':').?;
        const pos_1 = lastIndexOfScalarPos(u8, loc, pos_2, ':').?;
        return [3][]const u8{
            loc[0..pos_1],
            loc[pos_1 + 1 .. pos_2],
            loc[pos_2 + 1 ..],
        };
    }

    fn orderNormalizedUnsignedNumericStr(a: []const u8, b: []const u8) std.math.Order {
        switch (std.math.order(a.len, b.len)) {
            .lt => return .lt,
            .gt => return .gt,
            .eq => {},
        }
        return std.mem.order(u8, a, b);
    }
};

/// How is this not in the std lib?
fn statFileAbsolute(file_path: []const u8) std.fs.File.OpenError!std.fs.File.Stat {
    var file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    return file.stat();
}

/// How is this not in the std lib?
fn pump(reader: anytype, writer: anytype) !void {
    while (true) {
        var buf: [0x1000]u8 = undefined;
        const amount = try reader.read(&buf);
        if (amount == 0) break;
        try writer.writeAll(buf[0..amount]);
    }
}

/// How is this not in the std lib?
pub fn lastIndexOfScalarPos(comptime T: type, slice: []const T, start_index: usize, value: T) ?usize {
    var i: usize = start_index;
    while (i != 0) {
        i -= 1;
        if (slice[i] == value) return i;
    }
    return null;
}
