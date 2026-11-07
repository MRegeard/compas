const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Io = std.Io;
const Command = @import("command.zig").Command;
const ArgsIterator = @import("ArgsIterator.zig");

fn validateFields(comptime T: type) void {
    for (@typeInfo(T).@"struct".fields) |field| validateFieldType(field.type);
}

fn validateFieldType(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool => {},
        .optional => |o| validateFieldType(o.child),
        else => if (T != []const u8)
            @compileError("Unsupported type " ++ @typeName(T) ++ " for options/positionals."),
    }
}

pub const ParseError = error{
    UnknownCommand,
    MissingCommand,
    MissingPositionalArguements,
    TooManyPositionalArguments,
    ShortFlagEqualValueSyntaxError,
    MissingValue,
    UnknownOption,
    ParseBoolError,
} || std.fmt.ParseFloatError || std.fmt.ParseIntError;

pub const Config = struct {
    usage: enum { auto, custom } = .auto,
    helper: enum { auto, custom } = .auto,
    program_name: ?[]const u8 = null,
    program_description: ?[]const u8 = null,
};

pub fn Cli(comptime Context: type, comptime commands: []const Command, comptime config: Config) type {
    _ = config;
    for (commands) |cmd| {
        validateFields(cmd.Options);
        validateFields(cmd.Positionals);
    }

    const cmds_len: usize = commands.len;
    return struct {
        pub const Tag = blk: {
            const TagType: type = std.math.IntFittingRange(0, cmds_len + 1);
            var names: [cmds_len][]const u8 = undefined;
            var values: [cmds_len]TagType = undefined;
            for (commands, 0..) |cmd, i| {
                if (std.mem.eql(u8, cmd.name, "help")) @compileError("'help' is a reserved command name.");
                names[i] = cmd.name;
                values[i] = i;
            }
            const n = names;
            const v = values;
            break :blk @Enum(TagType, .exhaustive, &n, &v);
        };

        pub const Invoked = blk: {
            var field_names: [cmds_len][]const u8 = undefined;
            var field_types: [cmds_len]type = undefined;
            var field_attrs: [cmds_len]std.builtin.Type.UnionField.Attributes = undefined;
            for (commands, 0..) |cmd, i| {
                field_names[i] = cmd.name;
                field_types[i] = Payload(cmd);
                field_attrs[i] = .{};
            }
            const n = field_names;
            const t = field_types;
            const a = field_attrs;
            break :blk @Union(.auto, Tag, &n, &t, &a);
        };

        pub const ParseResult = union(enum) {
            command: Invoked,
            help: ?Tag,
            err: Diagnostic,
        };

        pub const Diagnostic = struct {
            tag: ?Tag = null,
            kind: ParseError = error.UnknownCommand,
            arg: ?[]const u8 = null,
            name: ?[]const u8 = null,
        };

        fn Payload(comptime command: Command) type {
            return struct {
                options: command.Options,
                positionals: command.Positionals,
            };
        }

        fn fail(diag: *Diagnostic, kind: ParseError, arg: ?[]const u8, name: ?[]const u8) ParseError {
            diag.kind = kind;
            diag.arg = arg;
            diag.name = name;
            return kind;
        }

        fn isHelp(name: []const u8) bool {
            return std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h");
        }

        pub fn parse(args: []const [:0]const u8) ParseResult {
            var arg_it = ArgsIterator.init(args);
            _ = arg_it.skip();
            if (arg_it.next()) |command_name| {
                if (isHelp(command_name)) return .{ .help = null };
                const tag = std.meta.stringToEnum(Tag, command_name) orelse return .{ .err = .{ .tag = null, .kind = error.UnknownCommand, .arg = command_name } };
                switch (tag) {
                    inline else => |t| {
                        var diag: Diagnostic = .{ .tag = t };
                        const cmd = commands[@intFromEnum(t)];
                        const payload = (parseCommandArgs(cmd, &arg_it, &diag) catch |err| {
                            assert(diag.kind == err);
                            return .{ .err = diag };
                        }) orelse return .{ .help = t };
                        return .{ .command = @unionInit(Invoked, @tagName(t), payload) };
                    },
                }
            }
            return .{ .err = .{ .kind = error.MissingCommand } };
        }

        fn parseCommandArgs(comptime cmd: Command, arg_it: *ArgsIterator, diag: *Diagnostic) ParseError!?Payload(cmd) {
            const required_positionals = comptime countRequiredPositional(cmd);

            var res: Payload(cmd) = .{
                .options = .{},
                .positionals = initPositional(cmd),
            };
            var pos_index: usize = 0;
            var only_positonal: bool = false;

            while (arg_it.next()) |arg| {
                if (!only_positonal and isHelp(arg)) return null;
                if (!only_positonal and std.mem.eql(u8, arg, "--")) {
                    only_positonal = true;
                } else if (!only_positonal and arg.len > 1 and arg[0] == '-') {
                    try parseOption(cmd, &res.options, arg, arg_it, diag);
                } else {
                    try setPositional(cmd, &res.positionals, pos_index, arg, diag);
                    pos_index += 1;
                }
            }
            if (pos_index < required_positionals) return fail(diag, error.MissingPositionalArguements, null, positionalName(cmd, pos_index));
            return res;
        }

        fn positionalName(comptime cmd: Command, idx: usize) []const u8 {
            inline for (@typeInfo(cmd.Positionals).@"struct".fields, 0..) |field, i| {
                if (i == idx) return field.name;
            }
            unreachable;
        }

        fn countRequiredPositional(comptime cmd: Command) usize {
            var n: usize = 0;
            var seen_optional: bool = false;
            inline for (@typeInfo(cmd.Positionals).@"struct".fields) |field| {
                const is_optional = field.default_value_ptr != null or @typeInfo(field.type) == .optional;
                if (is_optional) {
                    seen_optional = true;
                } else {
                    if (seen_optional) @compileError("Required postional '" ++ field.name ++ "' follows an optional one.");
                    n += 1;
                }
            }
            return n;
        }

        fn initPositional(comptime cmd: Command) cmd.Positionals {
            var p: cmd.Positionals = undefined;
            inline for (@typeInfo(cmd.Positionals).@"struct".fields) |field| {
                if (field.defaultValue()) |default| {
                    @field(p, field.name) = default;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(p, field.name) = null;
                }
            }
            return p;
        }

        fn setPositional(
            comptime cmd: Command,
            positionals: *cmd.Positionals,
            index: usize,
            arg: []const u8,
            diag: *Diagnostic,
        ) ParseError!void {
            inline for (@typeInfo(cmd.Positionals).@"struct".fields, 0..) |field, i| {
                if (i == index) {
                    @field(positionals.*, field.name) = parseValue(field.type, arg) catch |err|
                        return fail(diag, err, arg, field.name);
                    return;
                }
            }
            return fail(diag, error.TooManyPositionalArguments, arg, null);
        }

        fn shortChar(comptime cmd: Command, field_name: []const u8) ?u8 {
            const s = shortFor(cmd, field_name) orelse return null;
            if (s.len != 1) @compileError("Short name '" ++ s ++ "' for option '" ++ field_name ++ "' must be one character.");
            return s[0];
        }

        fn parseShortCluster(
            comptime cmd: Command,
            options: *cmd.Options,
            arg: []const u8,
            arg_it: *ArgsIterator,
            diag: *Diagnostic,
        ) ParseError!void {
            var i: usize = 1; // skip '-'
            while (i < arg.len) : (i += 1) {
                const char = arg[i];
                const matched = inline for (@typeInfo(cmd.Options).@"struct".fields) |field| {
                    if (comptime shortChar(cmd, field.name)) |s| {
                        if (s == char) {
                            if (field.type == bool) {
                                @field(options.*, field.name) = true;
                            } else {
                                const rest = arg[i + 1 ..];
                                if (rest.len > 0 and rest[0] == '=') return fail(diag, error.ShortFlagEqualValueSyntaxError, arg, field.name);
                                const value = if (rest.len > 0) rest else (arg_it.next() orelse return fail(diag, error.MissingValue, null, field.name));
                                @field(options.*, field.name) = parseValue(field.type, value) catch |err|
                                    return fail(diag, err, value, field.name);
                                return;
                            }
                            break true;
                        }
                    }
                } else false;
                if (!matched) return fail(diag, error.UnknownOption, arg[i .. i + 1], null);
            }
        }

        fn parseOption(comptime cmd: Command, options: *cmd.Options, arg: []const u8, arg_it: *ArgsIterator, diag: *Diagnostic) ParseError!void {
            if (!std.mem.startsWith(u8, arg, "--")) return parseShortCluster(cmd, options, arg, arg_it, diag);

            const arg_name: []const u8, const inline_value: ?[]const u8 =
                if (std.mem.indexOfScalar(u8, arg, '=')) |i| .{ arg[2..i], arg[i + 1 ..] } else .{ arg[2..], null };

            inline for (@typeInfo(cmd.Options).@"struct".fields) |field| {
                if (std.mem.eql(u8, arg_name, field.name)) {
                    if (field.type == bool) {
                        @field(options.*, field.name) = blk: {
                            if (inline_value) |v| {
                                break :blk parseValue(field.type, v) catch |err|
                                    return fail(diag, err, v, field.name);
                            } else {
                                break :blk true;
                            }
                        };
                    } else {
                        const value = inline_value orelse (arg_it.next() orelse return fail(diag, error.MissingValue, null, field.name));
                        @field(options.*, field.name) = parseValue(field.type, value) catch |err|
                            return fail(diag, err, value, field.name);
                    }
                    return;
                }
            }
            return fail(diag, error.UnknownOption, arg[0 .. 2 + arg_name.len], null);
        }

        fn parseValue(comptime T: type, arg: []const u8) ParseError!T {
            return switch (@typeInfo(T)) {
                .bool => {
                    if (std.ascii.eqlIgnoreCase(arg, "true")) return true;
                    if (std.ascii.eqlIgnoreCase(arg, "false")) return false;
                    return error.ParseBoolError;
                },
                .int => try std.fmt.parseInt(T, arg, 0),
                .float => try std.fmt.parseFloat(T, arg),
                .optional => |o| try parseValue(o.child, arg),
                else => if (T == []const u8) arg else @compileError("Unsupported option type: " ++ @typeName(T)),
            };
        }

        fn shortFor(comptime cmd: Command, comptime field_name: []const u8) ?[]const u8 {
            for (cmd.options_info) |info| {
                if (std.mem.eql(u8, info.longname, field_name)) return info.shortname;
            }
            return null;
        }

        pub fn run(invoked: Invoked, ctx: Context) !void {
            switch (invoked) {
                inline else => |payload, tag| {
                    const cmd = commands[@intFromEnum(tag)];
                    try call(cmd, ctx, payload);
                },
            }
        }

        fn call(comptime command: Command, ctx: Context, payload: Payload(command)) !void {
            const F = @TypeOf(command.Handler.?.run);
            var args: std.meta.ArgsTuple(F) = undefined;
            inline for (@typeInfo(F).@"fn".params, 0..) |param, i| {
                const T = param.type orelse @compileError("Generic parameters not supported in run.");
                args[i] = blk: {
                    if (T == command.Options) break :blk payload.options;
                    if (T == Context) break :blk ctx;
                    if (T == command.Positionals) break :blk payload.positionals;
                    break :blk fromContext(T, ctx);
                };
            }
            return @call(.auto, command.Handler.?.run, args);
        }

        fn fromContext(comptime T: type, ctx: Context) T {
            const fields = @typeInfo(Context).@"struct".fields;
            comptime var found: ?[]const u8 = null;
            inline for (fields) |f| {
                if (f.type == T) {
                    if (found != null) @compileError("Ambiguous: several context fields of type " ++ @typeName(T));
                    found = f.name;
                }
            }
            const name = found orelse @compileError("No context field of type " ++ @typeName(T) ++ " to pass to run.");
            return @field(ctx, name);
        }
    };
}
