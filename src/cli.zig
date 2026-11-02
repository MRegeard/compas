const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
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

pub fn Cli(comptime Context: type, comptime commands: []const Command) type {
    for (commands) |cmd| {
        validateFields(cmd.Options);
        validateFields(cmd.Positionals);
    }
    const cmds_len: usize = commands.len;
    return struct {
        pub const Tag = blk: {
            const TagType: type = std.math.IntFittingRange(0, commands.len);
            var names: [cmds_len][]const u8 = undefined;
            var values: [cmds_len]TagType = undefined;
            for (commands, 0..) |cmd, i| {
                names[i] = cmd.name;
                values[i] = i;
            }
            const n = names;
            const v = values;
            break :blk @Enum(TagType, .exhaustive, &n, &v);
        };

        pub const Parsed = blk: {
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

        fn Payload(comptime command: Command) type {
            return struct {
                options: command.Options,
                positionals: command.Positionals,
            };
        }

        pub fn parse(args: []const [:0]const u8) !Parsed {
            var arg_it = ArgsIterator.init(args);
            _ = arg_it.skip();
            if (arg_it.next()) |command_name| {
                const tag = std.meta.stringToEnum(Tag, command_name) orelse return error.UnknownCommand;
                return switch (tag) {
                    inline else => |t| blk: {
                        const cmd = commands[@intFromEnum(t)];
                        const parse_res = try parseCommandArgs(cmd, &arg_it);
                        break :blk @unionInit(Parsed, @tagName(t), .{
                            .options = parse_res.options,
                            .positionals = parse_res.positionals,
                        });
                    },
                };
            }
            return error.MissingCommand;
        }

        fn parseCommandArgs(comptime cmd: Command, arg_it: *ArgsIterator) !Payload(cmd) {
            const required_positionals = comptime countRequiredPositional(cmd);

            var res: Payload(cmd) = .{
                .options = .{},
                .positionals = initPositional(cmd),
            };
            var pos_index: usize = 0;
            var only_positonal: bool = false;

            while (arg_it.next()) |arg| {
                if (!only_positonal and std.mem.eql(u8, arg, "--")) {
                    only_positonal = true;
                } else if (!only_positonal and arg.len > 1 and arg[0] == '-') {
                    try parseOption(cmd, &res.options, arg, arg_it);
                } else {
                    try setPositional(cmd, &res.positionals, pos_index, arg);
                    pos_index += 1;
                }
            }
            if (pos_index < required_positionals) return error.MissingPositionalArguements;
            return res;
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

        fn setPositional(comptime cmd: Command, positionals: *cmd.Positionals, index: usize, arg: []const u8) !void {
            inline for (@typeInfo(cmd.Positionals).@"struct".fields, 0..) |field, i| {
                if (i == index) {
                    @field(positionals.*, field.name) = try parseValue(field.type, arg);
                    return;
                }
            }
            return error.TooManyPositionalArguments;
        }

        fn parseOption(comptime cmd: Command, options: *cmd.Options, arg: []const u8, arg_it: *ArgsIterator) !void {
            inline for (@typeInfo(cmd.Options).@"struct".fields) |field| {
                const short = comptime shortFor(cmd, field.name);
                if (matches(field.name, short, arg)) {
                    if (field.type == bool) {
                        @field(options, field.name) = true;
                    } else {
                        const value = arg_it.next() orelse return error.Missingvalue;
                        @field(options, field.name) = try parseValue(field.type, value);
                    }
                    return;
                }
            }
            return error.UnknownOption;
        }

        fn parseValue(comptime T: type, arg: []const u8) !T {
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

        fn matches(comptime long: []const u8, comptime short: ?[]const u8, arg: []const u8) bool {
            if (std.mem.startsWith(u8, arg, "--")) {
                return std.mem.eql(u8, arg[2..], long);
            }
            if (short) |s| {
                if (arg.len > 1 and arg[0] == '-') return std.mem.eql(u8, arg[1..], s);
            }
            return false;
        }

        fn shortFor(comptime cmd: Command, comptime field_name: []const u8) ?[]const u8 {
            for (cmd.options_info) |info| {
                if (std.mem.eql(u8, info.longname, field_name)) return info.shortname;
            }
            return null;
        }

        pub fn run(parsed: Parsed, ctx: Context) !void {
            switch (parsed) {
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
