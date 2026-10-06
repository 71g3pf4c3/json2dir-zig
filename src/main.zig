const std = @import("std");
const manifest = @import("manifest.zig");

const version_text = "json2dir-zig 0.1.0\n";

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

const max_input: usize = 1 << 30; // 1 GiB, plenty for a directory tree

const Cli = struct {
    input: ?[]const u8 = null,
    out: []const u8 = ".",
    dry_run: bool = false,
    verbose: bool = false,
    force: bool = true,
};

fn writeStdout(comptime text: []const u8) void {
    var buf: [8192]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    fw.interface.writeAll(text) catch {};
    fw.interface.flush() catch {};
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    var fw = std.fs.File.stderr().writer(&buf);
    const w = &fw.interface;
    w.print("json2dir: " ++ fmt ++ "\n", args) catch {};
    w.flush() catch {};
    std.process.exit(code);
}

fn usageError(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    var fw = std.fs.File.stderr().writer(&buf);
    const w = &fw.interface;
    w.print("json2dir: " ++ fmt ++ "\n\n", args) catch {};
    w.writeAll(usage_text) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

fn parseCli(gpa: std.mem.Allocator) !Cli {
    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    var cli = Cli{};
    var positional: ?[]const u8 = null;
    var no_more_flags = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];

        if (no_more_flags or arg.len < 2 or arg[0] != '-') {
            if (positional != null) usageError("unexpected extra argument '{s}'", .{arg});
            positional = arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            no_more_flags = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeStdout(usage_text);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            writeStdout(version_text);
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
            i += 1;
            if (i >= argv.len) usageError("option '{s}' requires a value", .{arg});
            cli.out = argv[i];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--out=")) {
            cli.out = arg["--out=".len..];
            continue;
        }

        usageError("unknown option '{s}'", .{arg});
    }

    cli.input = positional;
    return cli;
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const cli = try parseCli(gpa);

    // ---- read input ------------------------------------------------------

    const data: []u8 = blk: {
        if (cli.input) |path| {
            if (!std.mem.eql(u8, path, "-")) {
                var f = std.fs.cwd().openFile(path, .{}) catch |e| {
                    die(3, "cannot open '{s}': {s}", .{ path, @errorName(e) });
                };
                defer f.close();
                break :blk f.readToEndAlloc(gpa, max_input) catch |e| switch (e) {
                    error.StreamTooLong => die(3, "input exceeds the 1 GiB limit", .{}),
                    else => die(3, "cannot read '{s}': {s}", .{ path, @errorName(e) }),
                };
            }
        }
        const stdin = std.fs.File.stdin();
        break :blk stdin.readToEndAlloc(gpa, max_input) catch |e| switch (e) {
            error.StreamTooLong => die(3, "input exceeds the 1 GiB limit", .{}),
            else => die(3, "cannot read stdin: {s}", .{@errorName(e)}),
        };
    };

    // ---- parse --------------------------------------------------------

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch |e| {
        die(2, "invalid JSON: {s}", .{@errorName(e)});
    };
    defer parsed.deinit();

    // ---- resolve the target directory ---------------------------------

    // `null` (only for --dry-run) means "the target directory does not
    // exist": everything in the plan is new, and we create nothing —
    // not even --out itself. Wet runs get a real directory.
    var out_dir: ?std.fs.Dir = std.fs.cwd().openDir(cli.out, .{}) catch null;

    if (out_dir == null and !cli.dry_run) {
        std.fs.cwd().makePath(cli.out) catch |e| {
            die(3, "cannot create target directory '{s}': {s}", .{ cli.out, @errorName(e) });
        };
        out_dir = std.fs.cwd().openDir(cli.out, .{}) catch |e| {
            die(3, "cannot open target directory '{s}': {s}", .{ cli.out, @errorName(e) });
        };
    }
    defer if (out_dir) |*d| d.close();

    // ---- materialize ----------------------------------------------------

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    manifest.materialize(gpa, out_dir, parsed.value, .{
        .force = cli.force,
        .dry_run = cli.dry_run,
        .verbose = cli.verbose,
        .plan = if (cli.dry_run or cli.verbose) stdout else null,
    }) catch |e| switch (e) {
        error.ManifestFailed => std.process.exit(2),
        else => std.process.exit(3),
    };

    try stdout.flush();
}

test {
    _ = @import("manifest.zig");
}
