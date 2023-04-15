//! This code can parse a subset of bash syntax. (Similar to sh syntax.)
//! The motivational use case for this functionality was to interpret the sh commands that a build script would run.
//! When contrasted with Python's shlex module, the design emphasis of this code is
//! to parse and support slightly more complex constructs (control operators distinct from words, etc.),
//! and to report an error when unsupported constructs are found.
//!
//! Supported constructs and transformations:
//!  * comments are ignored
//!  * (lists of pipelines of) simple commands (partial support)
//!  * word splitting
//!  * quote removal
//!
//! Unsupported constructs and transformations:
//!  * any command starting with a reserved word (with no quotes or backslashes): ! case coproc do done elif else esac fi for function if in select then until while { } time [[ ]]
//!  * any occurrence of ( or ) except when inside 'single quotes' or "double quotes" or when prefixed by a \ .
//!  * all compound commands (due to the above)
//!  * pipelines that start with ! or time (due to the above).
//!  * shell function definitions (due to the above)
//!  * any occurrence of $ or ` except when inside 'single quotes' or when prefixed by \ . This means these are unsupported:
//!      * variable, parameter, and arithmetic expansion
//!      * command substitution
//!      * $'string' with escape sequences
//!      * $"string" with locale translation
//!  * any occurrence of ~ at the start of a word or immediately following a : or = (except at the start of a word) outside 'single quotes' or "double quotes". This means this is unsupported:
//!      * tilde expansion
//!  * any occurrence of any of { * ? [ > or < except when inside 'single quotes' or "double quotes" or when prefixed by \ . This means these are unsupported:
//!      * brace expansion
//!      * pathname expansion
//!      * process substitution
//!      * redirection (including here documents)
//!  * any occurrence of ! except when inside 'single quotes' or when prefixed by \ or when immediately followed by space, tab, newline, carriage return, = , or EOF. This means this is unsupported:
//!      * history expansion (almost all of it)
//!  * a ^ at the start of the first word of a command. This means this is unsupported:
//!      * history expansion (the rest of it)
//!  * any occurrence of = in the first word of a command except when inside 'single quotes' or "double quotes" or when prefixed by \ . This means this is unsupported:
//!      * variable assignment

const std = @import("std");

pub const BashParser = struct {
    arena: std.mem.Allocator,
    tokenizer: BashTokenizer,

    /// Note that this class leaks memory allocated with the given arena.
    pub fn init(arena: std.mem.Allocator, source: []const u8) @This() {
        return .{
            .arena = arena,
            .tokenizer = BashTokenizer.init(source),
        };
    }

    /// If the returned .control_operator is .eof, then this is the end.
    /// Subsequent calls will return an empty command with .control_operator = .eof forever.
    pub fn nextSimpleCommand(self: *@This()) !BashCommand {
        var cmd = std.ArrayList([]const u8).init(self.arena);
        while (true) {
            const token = try self.tokenizer.next();
            switch (token) {
                .bare_word => |content| {
                    if (cmd.items.len == 0) {
                        // Reject special bash things at the start of a command.
                        // Note that these would _not_ be special as a quoted_word.
                        if (reserved_words.has(content)) return error.UnsupportedReservedWord;
                        if (content[0] == '^') return error.UnsupportedHistoryExpansion;
                        if (std.mem.indexOfScalarPos(u8, content, 1, '=') != null) {
                            return error.UnsupportedVariableAssignment;
                        }
                    }
                    try cmd.append(content);
                },
                .quoted_word => |quoted_word| {
                    // This allocates memory.
                    try cmd.append(try removeQuotesAlloc(self.arena, quoted_word));
                },
                .pipe_pipe, .amp, .amp_amp, .semicolon, .pipe, .pipe_amp, .newline, .eof => {
                    return .{
                        .words = try cmd.toOwnedSlice(),
                        .control_operator = token,
                    };
                },
                .semicolon_semicolon, .semicolon_amp, .semicolon_semicolon_amp => return error.UnexpectedCaseControlOperator,
            }
        }
    }
};

pub const BashCommand = struct {
    words: []const []const u8,
    control_operator: BashToken,
};

const reserved_words = std.ComptimeStringMap(void, .{
    .{"!"},
    .{"case"},
    .{"coproc"},
    .{"do"},
    .{"done"},
    .{"elif"},
    .{"else"},
    .{"esac"},
    .{"fi"},
    .{"for"},
    .{"function"},
    .{"if"},
    .{"in"},
    .{"select"},
    .{"then"},
    .{"until"},
    .{"while"},
    .{"{"},
    .{"}"},
    .{"time"},
    .{"[["},
    .{"]]"},
});

pub const BashToken = union(enum) {
    /// The most common type of token. The payload is usable as the content of token.
    bare_word: []const u8,
    /// Call removeQuotesAlloc() to determine the meaning of the content of this token.
    quoted_word: []const u8,
    /// The OR operator between pipelines.
    pipe_pipe,
    /// The control operator that terminates a pipeline to indicate running in the background.
    amp,
    /// The AND operator between pipelines.
    amp_amp,
    /// The control operator that terminates a pipeline to indecate sequential execution.
    semicolon,
    /// Used in case statements.
    semicolon_semicolon,
    /// Used in case statements.
    semicolon_amp,
    /// Used in case statements.
    semicolon_semicolon_amp,
    /// The control operator between commands in a pipeline to indicate connecting stdout to the next command's stdin.
    pipe,
    /// The control operator between commands in a pipeline to indicate connecting stdout and stderr to the next command's stdin.
    pipe_amp,
    newline,
    eof,
};

/// TODO: The string can only be up to quoted_word.len - 1 bytes long. We don't really need an allocator parameter for this.
pub fn removeQuotesAlloc(allocator: std.mem.Allocator, quoted_word: []const u8) ![]const u8 {
    // Start with an approximate size.
    var s = try std.ArrayList(u8).initCapacity(allocator, quoted_word.len);
    var state: enum {
        none,
        backslash,
        double_quote,
        double_quote_backslash,
        single_quote,
    } = .none;
    for (quoted_word) |c| {
        switch (state) {
            .none => switch (c) {
                '\\' => {
                    state = .backslash;
                },
                '\'' => {
                    state = .single_quote;
                },
                '\"' => {
                    state = .double_quote;
                },
                else => {
                    try s.append(c);
                },
            },
            .backslash => switch (c) {
                '\n' => {
                    // This is a (mid-word) line continuation.
                    // Drop the escaped newline.
                    state = .none;
                },
                else => {
                    // All other characters are preserved literally by backslash.
                    try s.append(c);
                    // Note that the backslash itself is always dropped during this process,
                    // even if the escaped character isn't special.
                    state = .none;
                },
            },
            .double_quote => switch (c) {
                '\\' => {
                    state = .double_quote_backslash;
                },
                '\"' => {
                    state = .none;
                },
                else => {
                    try s.append(c);
                },
            },
            .double_quote_backslash => switch (c) {
                // > The backslash retains its special meaning only when followed by one of the following characters: $, `, ", \, or <newline>.
                '\n' => {
                    // Ignore line continuations.
                    state = .double_quote;
                },
                '$', '`', '"', '\\' => {
                    // Literal character.
                    try s.append(c);
                    state = .double_quote;
                },
                else => {
                    // The \ stays in the string (even for \!).
                    try s.appendSlice(&[_]u8{ '\\', c });
                    state = .double_quote;
                },
            },
            .single_quote => switch (c) {
                '\'' => {
                    state = .none;
                },
                else => {
                    try s.append(c);
                },
            },
        }
    }
    switch (state) {
        .none => {}, // clean done.
        .backslash => {}, // drop any trailing backslash before EOF.
        .double_quote, .double_quote_backslash, .single_quote => unreachable,
    }
    return s.toOwnedSlice();
}

pub const BashTokenizer = struct {
    state: enum {
        none,
        bare_word,
        bare_word_watchoutfortilde,
        double_quote,
        double_quote_bang,
        double_quote_backslash,
        single_quote,
        backslash,
        comment,

        pipe,
        amp,
        semicolon,
        semicolon_semicolon,
        bang,
    } = .none,
    input: []const u8,
    cursor: usize = 0,
    word_start: usize = undefined,
    word_is_bare: bool = undefined,

    pub fn init(input: []const u8) BashTokenizer {
        return .{ .input = input };
    }

    pub fn next(self: *@This()) !BashToken {
        while (true) {
            switch (self.state) {
                .none => switch (self.getC()) {
                    0 => {
                        return .eof;
                    },
                    '"' => {
                        self.state = .double_quote;
                        self.word_start = self.cursor - 1;
                        self.word_is_bare = false;
                    },
                    '\'' => {
                        self.state = .single_quote;
                        self.word_start = self.cursor - 1;
                        self.word_is_bare = false;
                    },
                    '\\' => {
                        self.state = .backslash;
                        self.word_start = self.cursor - 1;
                        self.word_is_bare = false;
                    },
                    ' ', '\t' => {
                        // doesn't mean anything.
                    },
                    '\n' => {
                        return .newline;
                    },
                    '|' => {
                        self.state = .pipe;
                    },
                    '&' => {
                        self.state = .amp;
                    },
                    ';' => {
                        self.state = .semicolon;
                    },
                    '(', ')', '<', '>', '~', '{', '*', '?', '[', '$', '`' => {
                        return error.UnsupportedBashFeature;
                    },
                    '!' => {
                        self.state = .bang;
                    },
                    '#' => {
                        self.state = .comment;
                    },
                    else => {
                        self.state = .bare_word;
                        self.word_start = self.cursor - 1;
                        self.word_is_bare = true;
                    },
                },
                .bare_word => switch (self.getC()) {
                    0 => {
                        return self.finishWord(self.input[self.word_start..]);
                    },
                    '|', '&', ';', '(', ')', '<', '>', '\n' => {
                        self.putBack();
                        return self.finishWord(self.input[self.word_start..self.cursor]);
                    },
                    ' ', '\t' => {
                        return self.finishWord(self.input[self.word_start .. self.cursor - 1]);
                    },
                    '$', '`', '{', '*', '?', '[' => {
                        return error.UnsupportedBashFeature;
                    },
                    '"' => {
                        self.state = .double_quote;
                        self.word_is_bare = false;
                    },
                    '\'' => {
                        self.state = .single_quote;
                        self.word_is_bare = false;
                    },
                    '\\' => {
                        self.state = .backslash;
                        self.word_is_bare = false;
                    },
                    ':', '=' => {
                        self.state = .bare_word_watchoutfortilde;
                    },
                    else => {},
                },
                .bare_word_watchoutfortilde => switch (self.getC()) {
                    '~' => return error.UnsupportedBashFeature,
                    0 => {
                        self.state = .bare_word;
                    },
                    else => {
                        self.putBack();
                        self.state = .bare_word;
                    },
                },
                .single_quote => switch (self.getC()) {
                    0 => return error.UnexpectedEof,
                    '\'' => {
                        self.state = .bare_word;
                    },
                    else => {},
                },
                .double_quote => switch (self.getC()) {
                    0 => return error.UnexpectedEof,
                    '"' => {
                        self.state = .bare_word;
                    },
                    '$', '`' => {
                        return error.UnsupportedBashFeature;
                    },
                    '!' => {
                        self.state = .double_quote_bang;
                    },
                    '\\' => {
                        self.state = .double_quote_backslash;
                    },
                    else => {},
                },
                .backslash => switch (self.getC()) {
                    0 => {
                        if (self.word_start == self.cursor - 1) {
                            // ignore this.
                            _ = self.finishWord(undefined);
                        } else {
                            // This trailing bare backslash will be deleted during quote removal.
                            self.state = .bare_word;
                        }
                    },
                    '\n' => {
                        // line continuation.
                        if (self.word_start == self.cursor - 2) {
                            // This is not a word.
                            _ = self.finishWord(undefined);
                        } else {
                            // This is part of a word, but it will be deleted.
                            self.state = .bare_word;
                        }
                    },
                    else => {
                        // All other characters are preserved literally by backslash.
                        self.state = .bare_word;
                    },
                },
                .double_quote_backslash => switch (self.getC()) {
                    0 => return error.UnexpectedEof,
                    else => {
                        // The meaning of this sequence will come up during quote removal.
                        self.state = .double_quote;
                    },
                },
                .comment => switch (self.getC()) {
                    0 => return .eof,
                    '\n' => {
                        self.state = .none;
                        return .newline;
                    },
                    else => {}, // ignore
                },
                .pipe => switch (self.getC()) {
                    0 => {
                        self.state = .none;
                        return .pipe;
                    },
                    '|' => {
                        self.state = .none;
                        return .pipe_pipe;
                    },
                    '&' => {
                        self.state = .none;
                        return .pipe_amp;
                    },
                    else => {
                        self.putBack();
                        self.state = .none;
                        return .pipe;
                    },
                },
                .amp => switch (self.getC()) {
                    0 => {
                        self.state = .none;
                        return .amp;
                    },
                    '&' => {
                        self.state = .none;
                        return .amp_amp;
                    },
                    else => {
                        self.putBack();
                        self.state = .none;
                        return .amp;
                    },
                },
                .semicolon => switch (self.getC()) {
                    0 => {
                        self.state = .none;
                        return .semicolon;
                    },
                    '&' => {
                        self.state = .none;
                        return .semicolon_amp;
                    },
                    ';' => {
                        self.state = .semicolon_semicolon;
                    },
                    else => {
                        self.putBack();
                        self.state = .none;
                        return .semicolon;
                    },
                },
                .semicolon_semicolon => switch (self.getC()) {
                    0 => {
                        self.state = .none;
                        return .semicolon_semicolon;
                    },
                    '&' => {
                        self.state = .none;
                        return .semicolon_semicolon_amp;
                    },
                    else => {
                        self.putBack();
                        self.state = .none;
                        return .semicolon_semicolon;
                    },
                },
                .bang => switch (self.getC()) {
                    0 => {
                        self.state = .none;
                    },
                    ' ', '\t', '\n', '\r', '=' => {
                        self.putBack();
                        self.state = .bare_word;
                    },
                    else => return error.UnsupportedBashFeature,
                },
                .double_quote_bang => switch (self.getC()) {
                    0 => return error.UnexpectedEof,
                    ' ', '\t', '\n', '\r', '=' => {
                        self.putBack();
                        self.state = .double_quote;
                    },
                    else => return error.UnsupportedBashFeature,
                },
            }
        }
    }

    fn finishWord(self: *@This(), slice: []const u8) BashToken {
        const token = if (self.word_is_bare) BashToken{ .bare_word = slice } else BashToken{ .quoted_word = slice };
        self.state = .none;
        self.word_start = undefined;
        self.word_is_bare = undefined;
        return token;
    }

    // because null bytes can't be used in bash source code, we use 0 as the EOF marker.
    fn getC(self: *@This()) u8 {
        if (self.cursor >= self.input.len) return 0;
        const c = self.input[self.cursor];
        self.cursor += 1;
        return c;
    }
    fn putBack(self: *@This()) void {
        self.cursor -= 1;
    }
};

fn expectToken(tag: std.meta.Tag(BashToken), token: BashToken) !void {
    try std.testing.expectEqual(tag, token);
}
fn expectTokenBareWord(expected: []const u8, token: BashToken) !void {
    try std.testing.expectEqualStrings(expected, token.bare_word);
}
fn expectTokenQuotedWord(expected: []const u8, token: BashToken) !void {
    const s = try removeQuotesAlloc(std.testing.allocator, token.quoted_word);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(expected, s);
}
test "BashTokenizer" {
    var tokenizer = BashTokenizer.init("echo hello");
    try expectTokenBareWord("echo", try tokenizer.next());
    try expectTokenBareWord("hello", try tokenizer.next());
    try expectToken(.eof, try tokenizer.next());

    tokenizer = BashTokenizer.init("echo 'hell o'");
    try expectTokenBareWord("echo", try tokenizer.next());
    try expectTokenQuotedWord("hell o", try tokenizer.next());
    try expectToken(.eof, try tokenizer.next());

    tokenizer = BashTokenizer.init(
    // unquoted backslash:
    "\\a\t\\$\n" ++
        // quoted backaslash:
        \\"\a	\$\
        \\b
        \\"
    );
    try expectTokenQuotedWord("a", try tokenizer.next());
    try expectTokenQuotedWord("$", try tokenizer.next());
    try expectToken(.newline, try tokenizer.next());
    try expectTokenQuotedWord("\\a\t$b\n", try tokenizer.next());
    try expectToken(.eof, try tokenizer.next());

    tokenizer = BashTokenizer.init(
        \\#echo ab
        \\echo #ab
        \\echo a#b
        \\echo a #b
        \\echo a# b
    );
    try expectToken(.newline, try tokenizer.next());
    try expectTokenBareWord("echo", try tokenizer.next());
    try expectToken(.newline, try tokenizer.next());
    try expectTokenBareWord("echo", try tokenizer.next());
    try expectTokenBareWord("a#b", try tokenizer.next());
    try expectToken(.newline, try tokenizer.next());
    try expectTokenBareWord("echo", try tokenizer.next());
    try expectTokenBareWord("a", try tokenizer.next());
    try expectToken(.newline, try tokenizer.next());
    try expectTokenBareWord("echo", try tokenizer.next());
    try expectTokenBareWord("a#", try tokenizer.next());
    try expectTokenBareWord("b", try tokenizer.next());
    try expectToken(.eof, try tokenizer.next());
}

fn expectSupport(supported: bool, script: []const u8) !void {
    var tokenizer = BashTokenizer.init(script);
    while (true) {
        const token = tokenizer.next() catch |err| switch (err) {
            error.UnsupportedBashFeature => {
                if (!supported) return;
                std.debug.print("Expected all features to be supported in this script:\n{s}\n", .{script});
                return error.TestExpectedSupported;
            },
            else => return err,
        };
        if (token == .eof) break;
    }
    if (supported) return;
    std.debug.print("Expected to detect an unsupported Bash feature in this script:\n{s}\n", .{script});
    return error.TestExpectedUnsupported;
}
test "BashTokenizer UnsupportedBashFeature" {
    try expectSupport(true, "");
    try expectSupport(false, "echo $PATH");
    try expectSupport(false, "echo \"$PATH\"");
    try expectSupport(true, "echo '$PATH'");
    try expectSupport(false, "echo /{tmp,bin}/");
    try expectSupport(false, "echo {0..10}");
    try expectSupport(true, "echo \"/{tmp,bin}/\"");
    try expectSupport(true, "echo '/{tmp,bin}/'");
    try expectSupport(false, "echo /{\"tmp\",bin}/");
    try expectSupport(false, "~/bin/program a");
    try expectSupport(true, "\"~/bin/program\" a");
    try expectSupport(true, "'~/bin/program' a");
    try expectSupport(false, "echo PATH=~/bin");
    try expectSupport(false, "echo PATH=a:~/bin");
    try expectSupport(true, "echo PATH=a%~/bin");
}
