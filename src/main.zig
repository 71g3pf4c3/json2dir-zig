// SPDX-License-Identifier: GPL-3.0-or-later
// json2dir-zig: materialize JSON documents as directory trees.
// Clean-room reimplementation of the json2dir conversion scheme.

const std = @import("std");
const manifest = @import("manifest.zig");
const build_info = @import("build_info");

const version_text = "json2dir-zig " ++ build_info.version ++ "\n";

const usage_text =
    \\Usage: json2dir [OPTIONS] [FILE]
    \\
    \\Materialize a JSON document as a directory tree. Reads stdin by default;
    \\with FILE, reads that file. The root of the document must be an object;
    \\its keys become entries of the target directory.
    \\
    \\Options:
    \\  -o, --out <DIR>    Target directory (default: .). Created if missing.
    \\  -n, --dry-run      Validate and print the plan; write nothing.
    \\  -v, --verbose      Print one line per entry while applying.
    \\      --no-clobber   Fail instead of replacing existing entries.
    \\  -h, --help         Print this help and exit.
    \\  -V, --version      Print version and exit.
    \\
    \\Conversion scheme:
    \\  object                -> directory (keys are entry names)
    \\  string                -> file (0644)
    \\  ["link", target]      -> symlink
    \\  ["script", contents]  -> executable file (0755)
    \\
    \\Files and symlinks are written to temporary names and rename(2)d into
    \\place; a run interrupted mid-tree never leaves a truncated file behind.
    \\Pre-existing entries are replaced by default (delete, then write);
    \\pass --no-clobber to refuse instead.
    \\
    \\Exit codes:
    \\  0  success
    \\  1  usage error
    \\  2  invalid input (bad JSON, bad manifest)
    \\  3  filesystem error
    \\
;

const max_input: u64 = 1 << 30; // 1 GiB, plenty for a directory tree

const Cli = struct {
    input: ?[]const u8 = null,
    out: []const u8 = ".",
    dry_run: bool = false,
    verbose: bool = false,
    force: bool = true,
};

fn printStdout(io: std.Io, comptime text: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}

fn die(io: std.Io, code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    w.print("json2dir: " ++ fmt ++ "\n", args) catch {};
    w.flush() catch {};
    std.process.exit(code);
}

fn usageError(io: std.Io, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    w.print("json2dir: " ++ fmt ++ "\n\n", args) catch {};
    w.writeAll(usage_text) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

fn parseCli(io: std.Io, args: std.process.Args) Cli {
    var cli = Cli{};
    var positional: ?[]const u8 = null;
    var no_more_flags = false;

    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // argv[0]

    while (it.next()) |arg| {
        if (no_more_flags or arg.len < 2 or arg[0] != '-') {
            if (positional != null) usageError(io, "unexpected extra argument '{s}'", .{arg});
            positional = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            no_more_flags = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printStdout(io, usage_text);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            printStdout(io, version_text);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            cli.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cli.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-clobber")) {
            cli.force = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            const value = it.next() orelse usageError(io, "option '{s}' requires a value", .{arg});
            cli.out = value;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--out=")) {
            cli.out = arg["--out=".len..];
            continue;
        }

        usageError(io, "unknown option '{s}'", .{arg});
    }

    cli.input = positional;
    return cli;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.arena.allocator();

    const cli = parseCli(io, init.minimal.args);

    // ---- read input ------------------------------------------------------

    const data: []u8 = blk: {
        if (cli.input) |path| {
            if (!std.mem.eql(u8, path, "-")) {
                var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
                    die(io, 3, "cannot open '{s}': {s}", .{ path, @errorName(e) });
                };
                defer f.close(io);
                var rbuf: [64 * 1024]u8 = undefined;
                var fr = f.readerStreaming(io, &rbuf);
                break :blk fr.interface.allocRemaining(gpa, .limited(max_input)) catch |e| switch (e) {
                    error.StreamTooLong => die(io, 3, "input exceeds the 1 GiB limit", .{}),
                    else => die(io, 3, "cannot read '{s}': {s}", .{ path, @errorName(e) }),
                };
            }
        }
        const stdin = std.Io.File.stdin();
        var rbuf: [64 * 1024]u8 = undefined;
        var fr = stdin.readerStreaming(io, &rbuf);
        break :blk fr.interface.allocRemaining(gpa, .limited(max_input)) catch |e| switch (e) {
            error.StreamTooLong => die(io, 3, "input exceeds the 1 GiB limit", .{}),
            else => die(io, 3, "cannot read stdin: {s}", .{@errorName(e)}),
        };
    };

    // ---- parse --------------------------------------------------------

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |e| {
        die(io, 2, "invalid JSON: {s}", .{@errorName(e)});
    };

    // ---- resolve the target directory ---------------------------------

    // `null` (only for --dry-run) means "the target directory does not
    // exist": everything in the plan is new, and we create nothing —
    // not even --out itself. Wet runs get a real directory.
    var out_dir: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, cli.out, .{}) catch null;

    if (out_dir == null and !cli.dry_run) {
        std.Io.Dir.cwd().createDirPath(io, cli.out) catch |e| {
            die(io, 3, "cannot create target directory '{s}': {s}", .{ cli.out, @errorName(e) });
        };
        out_dir = std.Io.Dir.cwd().openDir(io, cli.out, .{}) catch |e| {
            die(io, 3, "cannot open target directory '{s}': {s}", .{ cli.out, @errorName(e) });
        };
    }
    defer if (out_dir) |*d| d.close(io);

    // ---- materialize ----------------------------------------------------

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    manifest.materialize(io, gpa, out_dir, parsed.value, .{
        .force = cli.force,
        .dry_run = cli.dry_run,
        .verbose = cli.verbose,
        .plan = if (cli.dry_run or cli.verbose) stdout else null,
    }) catch |e| switch (e) {
        error.ManifestFailed => std.process.exit(2),
        else => std.process.exit(3),
    };

    try stdout.flush();
    return 0;
}

test {
    _ = @import("manifest.zig");
}
