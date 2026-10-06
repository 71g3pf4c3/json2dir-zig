// SPDX-License-Identifier: GPL-3.0-or-later
// json2dir-zig: materialize JSON documents as directory trees.
// Clean-room reimplementation of the json2dir conversion scheme.
//
//! Core: turn a parsed JSON document into a filesystem tree.
//!
//! Conversion scheme (drop-in compatible with alurm/json2dir):
//!
//!   object                -> directory; keys are entry names
//!   string                -> regular file (0644)
//!   ["link", target]      -> symlink
//!   ["script", contents]  -> executable file (0755)
//!
//! Everything else is a hard error. Names must be a single path segment
//! (no "/", ".", "..", NUL).
//!
//! Differences from upstream, on purpose:
//!   * files and symlinks are written to a temporary name in the target
//!     directory and `rename(2)`d into place, so replacing a file has no
//!     missing-file window and a concurrent reader never observes a
//!     truncated one;
//!   * temp files are created with O_CREAT|O_EXCL (`exclusive = true`),
//!     which never follows a pre-existing symlink at the temp path;
//!   * existence and type checks use lstat semantics
//!     (`follow_symlinks = false`), subdirectories are opened with
//!     `follow_symlinks = false`, so a pre-existing symlink at an entry
//!     path is replaced, never followed (see the `ln -s /` test below);
//!   * `--no-clobber` turns "delete before overwrite" into a refusal;
//!   * `--dry-run` validates the whole document and prints the plan
//!     without touching the filesystem.
//!
//! `?std.Io.Dir` threading: `null` means "this directory does not exist
//! yet" (dry-run beyond a not-yet-created parent, or a missing --out).
//! Existence checks against `null` return false, which is exactly the
//! future truth: nothing exists there. Wet runs always receive non-null.

const std = @import("std");
const Dir = std.Io.Dir;
const Io = std.Io;
const Permissions = std.Io.File.Permissions;

pub const file_mode: std.posix.mode_t = 0o644;
pub const exec_mode: std.posix.mode_t = 0o755;

pub const Options = struct {
    /// Replace existing entries (default: yes, matching upstream semantics).
    force: bool = true,
    /// Validate and print the plan; do not touch the filesystem.
    dry_run: bool = false,
    /// Print one line per entry.
    verbose: bool = false,
    /// Destination for the plan. `null` stays silent (tests, quiet runs).
    plan: ?*std.Io.Writer = null,
};

pub const NameError = error{
    EmptyName,
    SpecialSegment,
    PathSeparator,
    NulByte,
};

pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.SpecialSegment;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.PathSeparator;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.NulByte;
}

fn entryExists(io: Io, dir: ?Dir, name: []const u8) bool {
    const d = dir orelse return false;
    _ = d.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn isDirEntry(io: Io, dir: ?Dir, name: []const u8) bool {
    const d = dir orelse return false;
    const st = d.statFile(io, name, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .directory;
}

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    path: std.ArrayList(u8),

    fn plan(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        if (self.opts.plan) |w| {
            w.print(fmt ++ "\n", args) catch {};
        }
    }

    fn fail(self: *Ctx, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        var buf: [2048]u8 = undefined;
        var fw = std.Io.File.stderr().writer(self.io, &buf);
        const w = &fw.interface;
        const p = if (self.path.items.len == 0) "<root>" else self.path.items;
        w.print("json2dir: {s}: " ++ fmt ++ "\n", .{p} ++ args) catch {};
        w.flush() catch {};
        return err;
    }

    fn push(self: *Ctx, name: []const u8) !usize {
        const base = self.path.items.len;
        if (base != 0) try self.path.append(self.gpa, '/');
        try self.path.appendSlice(self.gpa, name);
        return base;
    }

    fn pop(self: *Ctx, base: usize) void {
        self.path.shrinkRetainingCapacity(base);
    }
};

fn replaceTag(replacing: bool) []const u8 {
    return if (replacing) "  (replacing)" else "";
}

/// Generate a random temp name ".<name>.json2dir-<8 hex>.tmp" into `buf`.
fn tempName(ctx: *Ctx, buf: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    var rand: [4]u8 = undefined;
    ctx.io.random(&rand);
    const suffix = std.mem.readInt(u32, &rand, .little);
    return std.fmt.bufPrint(buf, ".{s}.json2dir-{x}.tmp", .{ name, suffix }) catch error.NoSpaceLeft;
}

/// Write `data` as a file named `name` in `dir` with `mode`, atomically:
/// write to a temp name, chmod, rename over the target. Replacing a file
/// or symlink is a single rename(2): no window where the entry does not
/// exist, no partial content observable.
fn placeFile(
    ctx: *Ctx,
    dir: ?Dir,
    name: []const u8,
    data: []const u8,
    mode: std.posix.mode_t,
    comptime kind: []const u8,
) anyerror!void {
    const existed = entryExists(ctx.io, dir, name);
    if (existed and !ctx.opts.force) {
        return ctx.fail(error.ManifestFailed, "entry already exists and --no-clobber is set", .{});
    }

    if (!ctx.opts.dry_run) {
        const d = dir.?; // wet runs always receive a real directory
        // rename(2) over an existing directory fails; clear it out first.
        if (existed and isDirEntry(ctx.io, dir, name)) {
            d.deleteTree(ctx.io, name) catch |e| {
                return ctx.fail(error.IoFailed, "cannot remove existing directory: {s}", .{@errorName(e)});
            };
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        var f: std.Io.File = undefined;
        var tmp_name: []const u8 = "";
        var attempts: usize = 0;
        while (true) {
            tmp_name = tempName(ctx, &tmp_buf, name) catch {
                return ctx.fail(error.ManifestFailed, "entry name too long", .{});
            };
            // exclusive = O_CREAT|O_EXCL: never follows a symlink, and a
            // colliding name fails loudly instead of overwriting.
            if (d.createFile(ctx.io, tmp_name, .{
                .exclusive = true,
                .truncate = false,
                .permissions = .fromMode(mode),
            })) |file| {
                f = file;
                break;
            } else |e| switch (e) {
                error.PathAlreadyExists => {
                    attempts += 1;
                    if (attempts >= 8) {
                        return ctx.fail(error.IoFailed, "cannot create a temporary file: name collision", .{});
                    }
                },
                else => return ctx.fail(error.IoFailed, "cannot create file: {s}", .{@errorName(e)}),
            }
        }
        var installed = false;
        defer if (!installed) d.deleteFile(ctx.io, tmp_name) catch {};

        f.writeStreamingAll(ctx.io, data) catch |e| {
            f.close(ctx.io);
            return ctx.fail(error.IoFailed, "write failed: {s}", .{@errorName(e)});
        };
        // setPermissions after write: beats umask, guarantees scripts get 0755.
        f.setPermissions(ctx.io, .fromMode(mode)) catch |e| {
            f.close(ctx.io);
            return ctx.fail(error.IoFailed, "chmod failed: {s}", .{@errorName(e)});
        };
        f.close(ctx.io);

        d.rename(tmp_name, d, name, ctx.io) catch |e| {
            return ctx.fail(error.IoFailed, "cannot move file into place: {s}", .{@errorName(e)});
        };
        installed = true;
    }

    ctx.plan("{s:<6} {s}{s}", .{ kind, ctx.path.items, replaceTag(existed) });
}

/// Create a symlink `name` -> `target` in `dir`, atomically (temp name +
/// rename; replacing an existing symlink has no missing-entry window).
fn placeSymlink(ctx: *Ctx, dir: ?Dir, name: []const u8, target: []const u8) anyerror!void {
    const existed = entryExists(ctx.io, dir, name);
    if (existed and !ctx.opts.force) {
        return ctx.fail(error.ManifestFailed, "entry already exists and --no-clobber is set", .{});
    }

    if (!ctx.opts.dry_run) {
        const d = dir.?; // wet runs always receive a real directory
        if (existed and isDirEntry(ctx.io, dir, name)) {
            d.deleteTree(ctx.io, name) catch |e| {
                return ctx.fail(error.IoFailed, "cannot remove existing directory: {s}", .{@errorName(e)});
            };
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_name = tempName(ctx, &tmp_buf, name) catch {
            return ctx.fail(error.ManifestFailed, "entry name too long", .{});
        };

        d.symLink(ctx.io, target, tmp_name, .{}) catch |e| {
            return ctx.fail(error.IoFailed, "cannot create symlink: {s}", .{@errorName(e)});
        };
        d.rename(tmp_name, d, name, ctx.io) catch |e| {
            d.deleteFile(ctx.io, tmp_name) catch {};
            return ctx.fail(error.IoFailed, "cannot move symlink into place: {s}", .{@errorName(e)});
        };
    }

    ctx.plan("{s:<6} {s} -> {s}{s}", .{ "link", ctx.path.items, target, replaceTag(existed) });
}

fn children(ctx: *Ctx, dir: ?Dir, obj: *const std.json.ObjectMap) anyerror!void {
    var it = obj.iterator();
    while (it.next()) |kv| {
        try entry(ctx, dir, kv.key_ptr.*, kv.value_ptr.*);
    }
}

fn entry(ctx: *Ctx, dir: ?Dir, name: []const u8, value: std.json.Value) anyerror!void {
    // Push first so validation errors name the offending entry.
    const base = try ctx.push(name);
    defer ctx.pop(base);

    validateName(name) catch |e| switch (e) {
        error.EmptyName => return ctx.fail(error.ManifestFailed, "empty entry name", .{}),
        error.SpecialSegment => return ctx.fail(error.ManifestFailed, "'.' and '..' are not valid entry names", .{}),
        error.PathSeparator => return ctx.fail(error.ManifestFailed, "path separators are not allowed in entry names; nest objects instead", .{}),
        error.NulByte => return ctx.fail(error.ManifestFailed, "NUL byte in entry name", .{}),
    };

    switch (value) {
        .object => |obj| {
            const existed = entryExists(ctx.io, dir, name);
            if (existed and !ctx.opts.force) {
                return ctx.fail(error.ManifestFailed, "entry already exists and --no-clobber is set", .{});
            }

            // Preorder: the parent shows up before its children.
            ctx.plan("{s:<6} {s}{s}", .{ "dir", ctx.path.items, replaceTag(existed) });

            if (ctx.opts.dry_run) {
                // Read-only: open the existing subdirectory so that
                // existence checks (and --no-clobber) below it stay
                // faithful; `null` if it doesn't exist yet.
                const sub: ?Dir = if (existed)
                    (dir.?.openDir(ctx.io, name, .{ .follow_symlinks = false }) catch null)
                else
                    null;
                defer {
                    if (sub) |*s| s.close(ctx.io);
                }
                try children(ctx, sub, &obj);
            } else {
                const d = dir.?; // wet runs always receive a real directory
                if (existed) {
                    // deleteTree does not follow symlinks: a symlink at
                    // `name` is removed as a link, its target is left alone.
                    d.deleteTree(ctx.io, name) catch |e| {
                        return ctx.fail(error.IoFailed, "cannot remove existing entry: {s}", .{@errorName(e)});
                    };
                }
                d.createDir(ctx.io, name, .default_dir) catch |e| {
                    return ctx.fail(error.IoFailed, "mkdir: {s}", .{@errorName(e)});
                };
                var sub = d.openDir(ctx.io, name, .{ .follow_symlinks = false }) catch |e| {
                    return ctx.fail(error.IoFailed, "cannot open created directory: {s}", .{@errorName(e)});
                };
                defer sub.close(ctx.io);
                try children(ctx, sub, &obj);
            }
        },
        .string => |contents| {
            try placeFile(ctx, dir, name, contents, file_mode, "file");
        },
        .array => |arr| {
            if (arr.items.len != 2 or arr.items[0] != .string) {
                return ctx.fail(error.ManifestFailed, "arrays must be [\"link\", target] or [\"script\", contents]", .{});
            }
            const tag = arr.items[0].string;
            if (arr.items[1] != .string) {
                return ctx.fail(error.ManifestFailed, "\"{s}\" payload must be a string", .{tag});
            }
            const payload = arr.items[1].string;
            if (std.mem.eql(u8, tag, "link")) {
                try placeSymlink(ctx, dir, name, payload);
            } else if (std.mem.eql(u8, tag, "script")) {
                try placeFile(ctx, dir, name, payload, exec_mode, "exec");
            } else {
                return ctx.fail(error.ManifestFailed, "unknown array tag \"{s}\" (expected \"link\" or \"script\")", .{tag});
            }
        },
        .null, .bool, .integer, .float, .number_string => {
            return ctx.fail(error.ManifestFailed, "unsupported value type ({s}); use an object, a string, [\"link\", ...] or [\"script\", ...]", .{@tagName(value)});
        },
    }
}

/// Materialize `root` (a parsed JSON document) into `dir`.
/// `root` itself must be an object; its keys become entries of `dir`.
///
/// `dir == null` is allowed only for dry runs and means "the target
/// directory does not exist": everything is planned as new.
pub fn materialize(
    io: Io,
    gpa: std.mem.Allocator,
    dir: ?Dir,
    root: std.json.Value,
    opts: Options,
) anyerror!void {
    var ctx = Ctx{ .io = io, .gpa = gpa, .opts = opts, .path = .empty };
    defer ctx.path.deinit(gpa);

    if (dir == null and !opts.dry_run) {
        return ctx.fail(error.ManifestFailed, "internal: no target directory for a wet run", .{});
    }
    if (root != .object) {
        return ctx.fail(error.ManifestFailed, "the root of the JSON document must be an object", .{});
    }
    try children(&ctx, dir, &root.object);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectManifestError(src: []const u8, opts: Options) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    try testing.expectError(error.ManifestFailed, materialize(testing.io, testing.allocator, tmp.dir, parsed.value, opts));
}

test "validateName rejects garbage" {
    try testing.expectError(error.EmptyName, validateName(""));
    try testing.expectError(error.SpecialSegment, validateName("."));
    try testing.expectError(error.SpecialSegment, validateName(".."));
    try testing.expectError(error.PathSeparator, validateName("a/b"));
    try testing.expectError(error.PathSeparator, validateName("/etc/passwd"));
    try testing.expectError(error.NulByte, validateName("a\x00b"));
    try validateName("...");
    try validateName(".hidden");
    try validateName("a b");
    try validateName("-");
    try validateName("dot.json");
}

test "materialize: objects, files, link, script" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const src =
        \\{
        \\  "greeting": "Hello, world!",
        \\  "dir": {
        \\    "subfile": "Content.\n",
        \\    "subdir": {}
        \\  },
        \\  "symlink": ["link", "target path"],
        \\  "script": ["script", "#!/bin/sh\necho Howdy!"]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});

    const greeting = try tmp.dir.readFileAlloc(testing.io, "greeting", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(greeting);
    try testing.expectEqualStrings("Hello, world!", greeting);

    const subfile = try tmp.dir.readFileAlloc(testing.io, "dir/subfile", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(subfile);
    try testing.expectEqualStrings("Content.\n", subfile);

    var sub = try tmp.dir.openDir(testing.io, "dir/subdir", .{ .iterate = true });
    defer sub.close(testing.io);
    var it = sub.iterate();
    try testing.expect((try it.next(testing.io)) == null);

    var link_buf: [64]u8 = undefined;
    const n = try tmp.dir.readLink(testing.io, "symlink", &link_buf);
    try testing.expectEqualStrings("target path", link_buf[0..n]);

    const script = try tmp.dir.readFileAlloc(testing.io, "script", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(script);
    try testing.expectEqualStrings("#!/bin/sh\necho Howdy!", script);
    const st = try tmp.dir.statFile(testing.io, "script", .{});
    try testing.expect(st.kind == .file);
    try testing.expect(st.permissions.toMode() & 0o111 != 0);
}

test "materialize: rerun is idempotent with default force" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src =
        \\{"f": "one", "d": {"x": "two"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});
    const f = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("one", f);
}

test "materialize: --no-clobber refuses to replace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"one\"}", .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});
    try testing.expectError(
        error.ManifestFailed,
        materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{ .force = false }),
    );
}

test "materialize: --dry-run does not touch the filesystem" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"one\"}", .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{ .dry_run = true });
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "f", .{}));
}

test "materialize: dry-run + no-clobber is faithful against an existing tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"d\": {\"x\": \"y\"}}",
        .{},
    );
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});

    // dry-run with default force: fine, nothing written
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{ .dry_run = true });
    // dry-run with --no-clobber must fail exactly like the wet run would
    try testing.expectError(
        error.ManifestFailed,
        materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{ .dry_run = true, .force = false }),
    );
}

test "materialize: dry-run below a nonexistent parent treats everything as new" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"newdir\": {\"x\": \"y\"}}",
        .{},
    );
    defer parsed.deinit();
    // --out does not exist: dir == null, everything planned as new
    try materialize(testing.io, testing.allocator, null, parsed.value, .{ .dry_run = true, .force = false });
}

test "materialize: a pre-existing symlink at an entry path is replaced, not followed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Plant a symlink f -> /, so following it on write would be catastrophic.
    try tmp.dir.symLink(testing.io, "/", "f", .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"safe\"}", .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});
    const st = try tmp.dir.statFile(testing.io, "f", .{});
    try testing.expect(st.kind == .file);
    const f = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("safe", f);
}

test "materialize: unicode names, deep nesting, empty script" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const src =
        \\{
        \\  "héllo wörld.txt": "unicode",
        \\  "empty-script": ["script", ""],
        \\  "l1": {"l2": {"l3": {"l4": {"l5": {"l6": {"l7": {"l8": {"l9": {"bottom": "deep"}}}}}}}}}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});

    const u = try tmp.dir.readFileAlloc(testing.io, "héllo wörld.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("unicode", u);

    const deep = try tmp.dir.readFileAlloc(
        testing.io,
        "l1/l2/l3/l4/l5/l6/l7/l8/l9/bottom",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(deep);
    try testing.expectEqualStrings("deep", deep);

    const st = try tmp.dir.statFile(testing.io, "empty-script", .{});
    try testing.expect(st.kind == .file);
    try testing.expect(st.size == 0);
    try testing.expect(st.permissions.toMode() & 0o111 != 0);
}

test "materialize: replace updates content and mode changes survive rerun" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const first = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"one\"}", .{});
    defer first.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, first.value, .{});

    const second = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"two\"}", .{});
    defer second.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, second.value, .{});

    const f = try tmp.dir.readFileAlloc(testing.io, "f", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("two", f);
}

test "materialize: rejects unsupported documents" {
    try expectManifestError("[]", .{});
    try expectManifestError("\"just a string\"", .{});
    try expectManifestError("null", .{});
    try expectManifestError("{\"n\": 1}", .{});
    try expectManifestError("{\"b\": true}", .{});
    try expectManifestError("{\"a/b\": \"x\"}", .{});
    try expectManifestError("{\"\": \"x\"}", .{});
    try expectManifestError("{\"..\": \"x\"}", .{});
    try expectManifestError("{\"a\": [\"wat\", \"x\"]}", .{});
    try expectManifestError("{\"a\": [\"link\"]}", .{});
    try expectManifestError("{\"a\": [\"link\", 1]}", .{});
    try expectManifestError("{\"a\": [\"script\", \"x\", \"y\"]}", .{});
}

test "materialize: link to a directory is replaced without recursing into it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var victim = try tmp.dir.createDirPathOpen(testing.io, "victim/keep", .{});
    defer victim.close(testing.io);
    {
        var f = try victim.createFile(testing.io, "precious", .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, "do not delete");
    }
    try tmp.dir.symLink(testing.io, "victim", "d", .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"d\": {\"x\": \"y\"}}", .{});
    defer parsed.deinit();
    try materialize(testing.io, testing.allocator, tmp.dir, parsed.value, .{});

    // symlink replaced by a real dir; the victim survives untouched
    const st = try victim.statFile(testing.io, "precious", .{});
    try testing.expect(st.kind == .file);
    const x = try tmp.dir.readFileAlloc(testing.io, "d/x", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("y", x);
}
