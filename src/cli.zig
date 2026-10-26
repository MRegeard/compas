const std = @import("std");
const Command = @import("command.zig").Command;

fn validateType(comptime T: type) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .int, .float, .bool => return,
            .optional => |o| return validateType(@typeInfo(o).optional.child),
            else => if (field.type == []const u8) return else @compileError("Unsupported type " ++ @typeName(field.type) ++ " for options."),
        }
    }
}

pub fn Cli(comptime Context: type, comptime commands: []const Command) type {
    for (commands) |cmd| {
        validateType(cmd.Options);
        validateType(cmd.Positionals);
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
            };
        }

        pub fn parse(args: []const [:0]const u8) !Parsed {
            if (args.len < 2) return error.MissingCommand;
            const tag = std.meta.stringToEnum(Tag, args[1]) orelse return error.UnknownCommand;
            return switch (tag) {
                inline else => |t| blk: {
                    const cmd = commands[@intFromEnum(t)];
                    const options = try parseOptions(cmd, args[2..]);
                    break :blk @unionInit(Parsed, @tagName(t), .{ .options = options });
                },
            };
        }

        // For testing only 1 arg is parse as option, only bool options.
        fn parseOptions(comptime cmd: Command, args: []const [:0]const u8) !cmd.Options {
            const Options = cmd.Options;
            var options: Options = .{};
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                matched: {
                    inline for (@typeInfo(Options).@"struct".fields) |field| {
                        const short = comptime shortFor(cmd, field.name);
                        if (matches(field.name, short, arg)) {
                            if (field.type == bool) {
                                @field(options, field.name) = true;
                            } else {
                                i += 1;
                                if (i >= args.len) return error.MissingValue;
                                @field(options, field.name) = try parseValue(field.type, args[i]);
                            }
                            break :matched;
                        }
                    }
                    return error.UnknownOption;
                }
            }
            return options;
        }

        fn parseValue(comptime T: type, arg: []const u8) !T {
            return switch (@typeInfo(T)) {
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
                    try call(cmd, ctx, payload.options);
                },
            }
        }

        fn call(comptime command: Command, ctx: Context, opts: command.Options) !void {
            const F = @TypeOf(command.Handler.?.run);
            var args: std.meta.ArgsTuple(F) = undefined;
            inline for (@typeInfo(F).@"fn".params, 0..) |param, i| {
                const T = param.type orelse @compileError("Generic parameters not supported in run.");
                args[i] = if (T == command.Options) opts else if (T == Context) ctx else fromContext(T, ctx);
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
