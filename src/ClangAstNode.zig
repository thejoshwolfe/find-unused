id: []const u8 = "",
kind: []const u8 = "",
// either loc or loc.expansionLoc if present.
location: Location = .{},
// loc.spellingLoc if present.
secondary_locaction: Location = .{},
previous_decl: []const u8 = "",
mangled_name: []const u8 = "",
is_implicit: bool = false,
is_used: bool = false,
is_explicitly_deleted: bool = false,

pub const Location = struct {
    file: []const u8 = "",
    line: []const u8 = "",
    presumed_file: []const u8 = "",
    presumed_line: []const u8 = "",
    // This will always be non-blank if this location is present in the input.
    col: []const u8 = "",
};
