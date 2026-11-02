const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Args = std.process.Args;

const compas = @import("compas");
const Command = compas.Command;
const Cli = compas.Cli;
const Option = compas.Option;

const InitHandler = struct {
    pub fn run(gpa: Allocator, pos: init_command.Positionals, opts: init_command.Options) !void {
        _ = gpa;
        std.debug.print("Init: {s}, force = {any}, verbose = {any}, some = {any}\n", .{ pos.name, opts.force, opts.verbose, opts.some });
    }
};
const init_command: Command = .{ .name = "init", .description = "initialize ...", .Handler = InitHandler, .Options = struct {
    force: usize = 0,
    verbose: bool = false,
    some: bool = false,
}, .Positionals = struct {
    name: []const u8,
}, .options_info = &.{ .{
    .longname = "force",
    .shortname = "f",
    .description = "Force ...",
}, .{
    .longname = "verbose",
    .shortname = "v",
    .description = "Verbose ...",
}, .{
    .longname = "some",
    .shortname = "s",
    .description = "Some ...",
} }, .positionals_info = &.{.{
    .name = "dir",
    .description = "Folder name to init",
}} };

const VersionHandler = struct {
    pub fn run() !void {
        std.debug.print("Version\n", .{});
    }
};
const version_command: Command = .{
    .name = "version",
    .description = "Version ...",
    .Handler = VersionHandler,
};

const Context = struct {
    gpa: Allocator,
    io: Io,
};

const commands: [2]compas.Command = .{ init_command, version_command };

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    const cli = Cli(Context, &commands);
    const parsed = try cli.parse(args);
    try cli.run(parsed, .{ .gpa = allocator, .io = io });
}
