pub const OptionInfo = struct {
    longname: []const u8,
    shortname: []const u8,
    description: []const u8 = "",
};

pub const PositionalInfo = struct {
    name: []const u8,
    description: []const u8,
};

pub const Command = struct {
    name: []const u8,
    description: []const u8 = "",
    Positionals: type = struct {},
    Options: type = struct {},
    Handler: ?type = null,
    options_info: []const OptionInfo = &.{},
    positionals_info: []const PositionalInfo = &.{},
    order: bool = false,
};
