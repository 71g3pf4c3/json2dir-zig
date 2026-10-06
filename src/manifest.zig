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
//!   * files are opened with O_NOFOLLOW, subdirectories with
//!     AT_SYMLINK_NOFOLLOW, so a pre-existing symlink at an entry path
//!     is replaced, never followed (see the `ln -s /` test below);
//!   * `--no-clobber` turns "delete before overwrite" into a refusal;
//!   * `--dry-run` validates the whole document and prints the plan
//!     without touching the filesystem.
//!
//! `?std.fs.Dir` threading: `null` means "this directory does not exist
//! yet" (dry-run beyond a not-yet-created parent, or a missing --out).
//! Existence checks against `null` return false, which is exactly the
//! future truth: nothing exists there. Wet runs always receive non-null.

const std = @import("std");

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

fn entryExists(dir: ?std.fs.Dir, name: []const u8) bool {
    const d = dir orelse return false;
    _ = std.posix.fstatat(d.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

fn isDirEntry(dir: ?std.fs.Dir, name: []const u8) bool {
    const d = dir orelse return false;
    const st = std.posix.fstatat(d.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return (st.mode & std.posix.S.IFMT) == std.posix.S.IFDIR;
}

const Ctx = struct {
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
        var fw = std.fs.File.stderr().writer(&buf);
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

/// Write `data` as a file named `name` in `dir` with `mode`, atomically:
/// write to `.name.json2dir-<rand>.tmp`, chmod, rename over the target.
/// Replacing a file or symlink is a single rename(2): no window where the
/// entry does not exist, no partial content observable.
fn placeFile(
    ctx: *Ctx,
    dir: ?std.fs.Dir,
    name: []const u8,
    data: []const u8,
    mode: std.posix.mode_t,
    comptime kind: []const u8,
) anyerror!void {
    const existed = entryExists(dir, name);
    if (existed and !ctx.opts.force) {
        return ctx.fail(error.ManifestFailed, "entry already exists and --no-clobber is set", .{});
    }

    if (!ctx.opts.dry_run) {
        const d = dir.?; // wet runs always receive a real directory
        // rename(2) over an existing directory fails; clear it out first.
        if (existed and isDirEntry(dir, name)) {
            d.deleteTree(name) catch |e| {
                return ctx.fail(error.IoFailed, "cannot remove existing directory: {s}", .{@errorName(e)});
            };
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}.json2dir-{x}.tmp", .{
            name, std.crypto.random.int(u32),
        }) catch {
            return ctx.fail(error.ManifestFailed, "entry name too long", .{});
        };

        var f = d.createFile(tmp_name, .{ .no_follow = true, .mode = mode }) catch |e| {
            return ctx.fail(error.IoFailed, "cannot create file: {s}", .{@errorName(e)});
        };
        var installed = false;
        defer if (!installed) d.deleteFile(tmp_name) catch {};

        f.writeAll(data) catch |e| {
            f.close();
            return ctx.fail(error.IoFailed, "write failed: {s}", .{@errorName(e)});
        };
        // chmod after write: beats umask, guarantees scripts get 0755.
        f.chmod(mode) catch |e| {
            f.close();
            return ctx.fail(error.IoFailed, "chmod failed: {s}", .{@errorName(e)});
        };
        f.close();

        d.rename(tmp_name, name) catch |e| {
            return ctx.fail(error.IoFailed, "cannot move file into place: {s}", .{@errorName(e)});
        };
        installed = true;
    }

    ctx.plan("{s:<6} {s}{s}", .{ kind, ctx.path.items, replaceTag(existed) });
}

/// Create a symlink `name` -> `target` in `dir`, atomically (temp name +
/// rename; replacing an existing symlink has no missing-entry window).
fn placeSymlink(ctx: *Ctx, dir: ?std.fs.Dir, name: []const u8, target: []const u8) anyerror!void {
    const existed = entryExists(dir, name);
    if (existed and !ctx.opts.force) {
        return ctx.fail(error.ManifestFailed, "entry already exists and --no-clobber is set", .{});
    }

    if (!ctx.opts.dry_run) {
        const d = dir.?; // wet runs always receive a real directory
        if (existed and isDirEntry(dir, name)) {
            d.deleteTree(name) catch |e| {
                return ctx.fail(error.IoFailed, "cannot remove existing directory: {s}", .{@errorName(e)});
            };
        }

        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, ".{s}.json2dir-{x}.tmp", .{
            name, std.crypto.random.int(u32),
        }) catch {
            return ctx.fail(error.ManifestFailed, "entry name too long", .{});
        };

        d.symLink(target, tmp_name, .{}) catch |e| {
            return ctx.fail(error.IoFailed, "cannot create symlink: {s}", .{@errorName(e)});
        };
        d.rename(tmp_name, name) catch |e| {
            d.deleteFile(tmp_name) catch {};
            return ctx.fail(error.IoFailed, "cannot move symlink into place: {s}", .{@errorName(e)});
        };
    }

    ctx.plan("{s:<6} {s} -> {s}{s}", .{ "link", ctx.path.items, target, replaceTag(existed) });
}

fn children(ctx: *Ctx, dir: ?std.fs.Dir, obj: *const std.json.ObjectMap) anyerror!void {
    var it = obj.iterator();
    while (it.next()) |kv| {
        try entry(ctx, dir, kv.key_ptr.*, kv.value_ptr.*);
    }
}

fn entry(ctx: *Ctx, dir: ?std.fs.Dir, name: []const u8, value: std.json.Value) anyerror!void {
    validateName(name) catch |e| switch (e) {
        error.EmptyName => return ctx.fail(error.ManifestFailed, "empty entry name", .{}),
        error.SpecialSegment => return ctx.fail(error.ManifestFailed, "'.' and '..' are not valid entry names", .{}),
        error.PathSeparator => return ctx.fail(error.ManifestFailed, "path separators are not allowed in entry names; nest objects instead", .{}),
        error.NulByte => return ctx.fail(error.ManifestFailed, "NUL byte in entry name", .{}),
    };

    const base = try ctx.push(name);
    defer ctx.pop(base);

    switch (value) {
        .object => |obj| {
            const existed = entryExists(dir, name);
            if (existed and !ctx.opts.force) {
                return ctx.fail(error.ManifestFailed, "entry already exists and --no-clobber is set", .{});
            }

            // Preorder: the parent shows up before its children.
            ctx.plan("{s:<6} {s}{s}", .{ "dir", ctx.path.items, replaceTag(existed) });

            if (ctx.opts.dry_run) {
                // Read-only: open the existing subdirectory so that
                // existence checks (and --no-clobber) below it stay
                // faithful; `null` if it doesn't exist yet.
                const sub: ?std.fs.Dir = if (existed)
                    (dir.?.openDir(name, .{ .no_follow = true }) catch null)
                else
                    null;
                if (sub) |s| defer s.close();
                try children(ctx, sub, &obj);
            } else {
                const d = dir.?; // wet runs always receive a real directory
                if (existed) {
                    // deleteTree does not follow symlinks: a symlink at
                    // `name` is removed as a link, its target is left alone.
                    d.deleteTree(name) catch |e| {
                        return ctx.fail(error.IoFailed, "cannot remove existing entry: {s}", .{@errorName(e)});
                    };
                }
                d.makeDir(name) catch |e| {
                    return ctx.fail(error.IoFailed, "mkdir: {s}", .{@errorName(e)});
                };
                var sub = d.openDir(name, .{ .no_follow = true }) catch |e| {
                    return ctx.fail(error.IoFailed, "cannot open created directory: {s}", .{@errorName(e)});
                };
                defer sub.close();
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
    gpa: std.mem.Allocator,
    dir: ?std.fs.Dir,
    root: std.json.Value,
    opts: Options,
) anyerror!void {
    var ctx = Ctx{ .gpa = gpa, .opts = opts, .path = .empty };
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
    try testing.expectError(error.ManifestFailed, materialize(testing.allocator, tmp.dir, parsed.value, opts));
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
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});

    const greeting = try tmp.dir.readFileAlloc(testing.allocator, "greeting", 1 << 20);
    defer testing.allocator.free(greeting);
    try testing.expectEqualStrings("Hello, world!", greeting);

    const subfile = try tmp.dir.readFileAlloc(testing.allocator, "dir/subfile", 1 << 20);
    defer testing.allocator.free(subfile);
    try testing.expectEqualStrings("Content.\n", subfile);

    var sub = try tmp.dir.openDir("dir/subdir", .{});
    defer sub.close();
    var it = sub.iterate();
    try testing.expect((try it.next()) == null);

    var link_buf: [64]u8 = undefined;
    const target = try tmp.dir.readLink("symlink", &link_buf);
    try testing.expectEqualStrings("target path", target);

    const script = try tmp.dir.readFileAlloc(testing.allocator, "script", 1 << 20);
    defer testing.allocator.free(script);
    try testing.expectEqualStrings("#!/bin/sh\necho Howdy!", script);
    const st = try tmp.dir.statFile("script");
    try testing.expect(st.mode & 0o111 != 0);
}

test "materialize: rerun is idempotent with default force" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src = \\{"f": "one", "d": {"x": "two"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});
    const f = try tmp.dir.readFileAlloc(testing.allocator, "f", 1 << 20);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("one", f);
}

test "materialize: --no-clobber refuses to replace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"one\"}", .{});
    defer parsed.deinit();
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});
    try testing.expectError(
        error.ManifestFailed,
        materialize(testing.allocator, tmp.dir, parsed.value, .{ .force = false }),
    );
}

test "materialize: --dry-run does not touch the filesystem" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"one\"}", .{});
    defer parsed.deinit();
    try materialize(testing.allocator, tmp.dir, parsed.value, .{ .dry_run = true });
    try testing.expectError(error.FileNotFound, tmp.dir.access("f", .{}));
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
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});

    // dry-run with default force: fine, nothing written
    try materialize(testing.allocator, tmp.dir, parsed.value, .{ .dry_run = true });
    // dry-run with --no-clobber must fail exactly like the wet run would
    try testing.expectError(
        error.ManifestFailed,
        materialize(testing.allocator, tmp.dir, parsed.value, .{ .dry_run = true, .force = false }),
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
    try materialize(testing.allocator, null, parsed.value, .{ .dry_run = true, .force = false });
}

test "materialize: a pre-existing symlink at an entry path is replaced, not followed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Plant a symlink f -> /, so following it on write would be catastrophic.
    try tmp.dir.symLink("/", "f", .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"f\": \"safe\"}", .{});
    defer parsed.deinit();
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});
    const st = try tmp.dir.statFile("f");
    try testing.expect(st.kind == .file);
    const f = try tmp.dir.readFileAlloc(testing.allocator, "f", 1 << 20);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("safe", f);
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
    try tmp.dir.makePath("victim/keep");
    const victim_file = try tmp.dir.createFile("victim/keep/precious", .{});
    try victim_file.writeAll("do not delete");
    try victim_file.close();
    try tmp.dir.symLink("victim", "d", .{});

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"d\": {\"x\": \"y\"}}", .{});
    defer parsed.deinit();
    try materialize(testing.allocator, tmp.dir, parsed.value, .{});

    // symlink replaced by a real dir; the victim survives untouched
    const st = try tmp.dir.statFile("victim/keep/precious");
    try testing.expect(st.kind == .file);
    var d = try tmp.dir.openDir("d", .{});
    defer d.close();
    const x = try tmp.dir.readFileAlloc(testing.allocator, "d/x", 1 << 20);
    defer testing.allocator.free(x);
    try testing.expectEqualStrings("y", x);
}
