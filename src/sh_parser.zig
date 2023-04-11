//! See `man bash` for the reference for this module.
//! This only implements a subset that I find useful.
//! Note that unlike python's shlex module, this parser can distinguish between these:
//!  $ a=b cmd1 && cmd2
//!  $ "a=b" cmd1 "&&" cmd2
//! Unfortunately, this means that the API here is very complex compared to just an array of strings.

const std = @import("std");
const ListOf = std.ArrayListUnmanaged;

pub const ShProgram = struct {
    pipelines: ListOf(ShPipeline) = .{},
};
/// The official grammar is:
///   [time [-p]] [ ! ] command [ [|⎪|&] command2 ... ]
pub const ShPipeline = struct {
    time_flags: enum {
        none,
        time,
        time_p,
    } = .none,
    negated: bool = false,
    commands: ListOf(ShCommand) = .{},
};
pub const ShCommand = union(enum) {
    simple_command: ShSimpleCommand,
    /// Unimplemented.
    compound_command: void,
};
pub const ShSimpleCommand = struct {
    /// Unimplemented.
    variable_assignments: void = {},
    tokens: ShTokenList,
    /// Unimplemented.
    redirections: void = {},
    /// The documented list is:
    ///   || & && ; ;; ( ) | |& <newline>
    /// and we also add eof, which seems to be equivalent to <newline>.
    control_operator: enum {
        pipe_pipe,
        amp,
        amp_amp,
        semicolon,
        semicolon_semicolon,
        l_paren,
        r_paren,
        pipe,
        pipe_amp,
        newline,
        eof,
    },
};

pub const ShTokenList = struct {
    /// The documented list:
    ///  brace expansion, tilde expansion, parameter, variable and arithmetic expansion and command substitution (done in a left-to-right fashion), word splitting, and pathname expansion
    transformations: packed struct {
        brace_expansion: bool,
        tilde_expansion: bool,
        parameter_or_variable_or_arithmetic_expansion: bool,
        command_substitution: bool,
        process_substitution: bool,
        word_splitting: bool,
        quote_removal: bool,
        pathname_expansion: bool,
    },

    sequences: ListOf(ShSequence) = .{},

    pub fn resolveSimple(self: @This(), allocator: std.mem.Allocator) ![]const []const u8 {
        @panic("TODO");
    }
};

pub const ShSequence = union(enum) {
    plain: []const u8,
    double_quote_begin,
    double_quote_end,
    single_quote_begin,
    single_quote_end,
    word_break,

    /// Unimplemented:
    brace_expansion_begin,
    brace_expansion_comma,
    brace_expansion_end,
    tilde_expansion,
    simple_variable_expansion,
    variable_expansion_start,
    variable_expansion_start,
    parameter_expansion,
    variable_expansion,
    arithmetic_substitution,
    command_substitution,
    process_substitution,
    pathname_expansion,
};

pub fn parseShScript(arena: std.mem.Allocator, sh_script: []const u8) !ShProgram {
}
