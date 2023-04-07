const std = @import("std");

pub const ClangCommand = struct {
    /// TODO: there can sometimes be multiple source files.
    source_file: []const u8,
    output_file: []const u8,
    is_compile: bool,
};

/// Parse some basic things out of a clang command.
/// TODO: get real fancy by vendoring and parsing these:
///  * https://github.com/llvm/llvm-project/blob/main/llvm/include/llvm/Option/OptParser.td
///  * https://github.com/llvm/llvm-project/blob/main/clang/include/clang/Driver/Options.td
pub fn parseClangCli(cmd: []const []const u8) ?ClangCommand {
    if (cmd.len < 3) return null;
    if (!std.mem.startsWith(u8, std.fs.path.basename(cmd[0]), "clang")) return null;

    var source_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var is_compile = false;
    for (cmd[0 .. cmd.len - 1], 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-o")) {
            output_file = cmd[i + 1];
        } else if (std.mem.eql(u8, arg, "-c")) {
            is_compile = true;
        }
    }
    // TODO: don't assume the source file is the last argument.
    for (clang_file_extensions) |ext| {
        if (std.mem.endsWith(u8, cmd[cmd.len - 1], ext)) {
            source_file = cmd[cmd.len - 1];
        }
    }

    if (source_file == null or output_file == null) return null;
    return .{
        .source_file = source_file.?,
        .output_file = output_file.?,
        .is_compile = is_compile,
    };
}

const c_file_extensions = [_][]const u8{".c"};
const cpp_file_extensions = [_][]const u8{ ".C", ".cc", ".cpp", ".cxx", ".c++" };
const clang_file_extensions = c_file_extensions ++ cpp_file_extensions;
