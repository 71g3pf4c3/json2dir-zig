# json2dir-zig

> JSON documents → directory trees. Drop-in compatible with
> [alurm/json2dir](https://github.com/alurm/json2dir) — minus the footguns.

[![CI](https://github.com/71g3pf4c3/json2dir-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/71g3pf4c3/json2dir-zig/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

`json2dir` is a genuinely nice idea: a declarative, diffable, grep-able format
for describing a tree of files, directories, symlinks and executables, and a
tiny tool that turns it into a real tree. The original implementation,
however, is the idea wrapped in a tool you should not point at anything you
care about. This is a from-scratch reimplementation in Zig: **same conversion
scheme, same JSON in, same tree out** — with the sharp edges ground off.

```
$ cat example-tree.json
{
  "greeting": "Hello, world!",
  "dir": { "subfile": "Content.\n", "subdir": {} },
  "symlink": ["link", "target path"],
  "script":  ["script", "#!/bin/sh\necho Howdy!"]
}

$ json2dir -n example-tree.json
file   greeting
dir    dir
file   dir/subfile
dir    dir/subdir
link   symlink -> target path
exec   script

$ json2dir -o out example-tree.json
$ ./out/script
Howdy!
```

One static binary. Zero runtime dependencies. No interpreter, no cargo, no
libc even (see [`json2dir-static`](#install)). Std-only Zig — the JSON parser
is `std.json`, because for a schema-less document tree a third-party
serializer buys nothing. Ships with a man page (`json2dir(1)`) and shell
completions for bash, zsh and fish.

---

## Why a rewrite: a review of upstream

These are not strawmen — every quoted phrase below is from upstream's own
README. The problem isn't that the problems are undocumented; it's that
they're documented and shipped.

### 1. TOCTOU: *"makes no attempt to guard against such attacks"*

For a tool whose advertised use case is **materializing trees of files and
symlinks — for other users** (its own dotfiles pitch). The failure mode is
boring and classic: plant a symlink at a path where the manifest expects a
file, and the "delete then write" logic operates on whatever the link points
at. `json2dir`'s answer is a README paragraph that says "care must be taken".

This rewrite's answer:

* files are created with `O_NOFOLLOW` — a symlink at the entry path makes
  the create fail, it never gets followed;
* existence and type checks use `fstatat(2)` with `AT_SYMLINK_NOFOLLOW`;
* subdirectories are opened with `O_NOFOLLOW`;
* a pre-existing symlink at an entry path is **replaced, not followed**
  (there is a test that plants `ln -s / f` and asserts the write doesn't
  land in `/`).

### 2. Destructive and blind

*"json2dir tries to delete a file or a directory before overwriting it."*

Note the verb. Every replaced entry — file, symlink, directory, doesn't
matter — is unlinked first and written second. There is no dry-run. There is
no preview. There is no opt-out of the deletion. Every config applier on
earth (`nix`, `terraform`, `apt`, `kubectl`) grew a "show me first" mode
because rm-and-pray doesn't survive contact with production; this one ships
without one.

Here:

* `--dry-run` (`-n`) validates the **entire** document and prints the plan
  without touching the filesystem — it doesn't even create `--out` if it
  doesn't exist;
* `--dry-run --no-clobber` is *faithful*: existing subdirectories are opened
  read-only during the dry run, so the refusal you see in the plan is the
  refusal you'd get for real;
* `--no-clobber` turns replacement into a hard error naming the path.

### 3. Torn writes

Delete-then-write means every replaced file has a window where it **does not
exist**, and every fresh file has a window where it is **partially written**.
Kill the process mid-run and you keep the rubble; a reader racing the writer
sees a truncated file.

Here, files and symlinks are written under a temporary name in the target
directory and `rename(2)`d into place:

* replacing a file or symlink is a single `rename(2)` — **no window where the
  entry is missing**, no partial content ever observable;
* a crash mid-tree leaves the tree half-*new*, not half-*deleted* — every
  completed entry is complete (see [known holes](#whats-still-not-fixed) for
  the directory case, which is documented, not hidden).

### 4. cwd-only

Upstream writes to the current directory, full stop. Want to apply into
`/srv/app`? `cd /srv/app && json2dir < tree.json` in your script, and pray
nothing else in that script depended on cwd. Composes beautifully with CI
steps, systemd units and nix builds, doesn't it.

Here: `--out DIR` (created on demand for wet runs), a `FILE` positional, and
`-` for explicit stdin.

### 5. Arrays as a tagged union

`["link", target]` / `["script", contents]` — a JSON array hijacked as a poor
man's tagged union. It cannot express a file mode, ownership, or a hardlink;
a two-element array whose first element isn't exactly `"link"` or `"script"`
is an error; and the *type* of an array is decided by peeking at a string
inside it.

**Kept, deliberately.** Byte-for-byte compatibility with every existing
tree.json beats a prettier schema, and inventing a second encoding would
fork the ecosystem for zero gain. The semantics *around* the encoding is
where the fixes went: e.g. script files get an explicit `chmod 0755` after
write, so they're executable regardless of the caller's umask.

### 6. Inherited honestly

Two more upstream caveats that aren't fixed here either, because "fixing"
them would be lying:

* **UTF-8 only.** JSON strings are Unicode; arbitrary bytes are not
  representable. Same in any implementation of this scheme.
* **No Windows.** Symlinks, modes and `rename(2)` semantics are Unix. Same
  as upstream.

---

## Usage

```
Usage: json2dir [OPTIONS] [FILE]

Materialize a JSON document as a directory tree. Reads stdin by default;
with FILE, reads that file. The root of the document must be an object;
its keys become entries of the target directory.

Options:
  -o, --out <DIR>    Target directory (default: .). Created if missing.
  -n, --dry-run      Validate and print the plan; write nothing.
  -v, --verbose      Print one line per entry while applying.
      --no-clobber   Fail instead of replacing existing entries.
  -h, --help         Print this help and exit.
  -V, --version      Print version and exit.
```

Exit codes:

| code | meaning                                        |
| ---- | ---------------------------------------------- |
| `0`  | success                                        |
| `1`  | usage error                                    |
| `2`  | invalid input (bad JSON, bad manifest)         |
| `3`  | filesystem error                              |

Plan line format (dry-run and verbose):

```
dir    path/to/dir            directory (created or replaced)
file   path/to/file           regular file, 0644
exec   path/to/script         executable file, 0755
link   path -> target         symlink
```

Entries that replace something existing are suffixed `(replacing)`. The plan
is printed in document order (std.json preserves object key order), which
makes it diffable against the JSON you feed in.

Errors name the JSON path of the offending entry: `json2dir: dir/subdir/x: ...`.

## Conversion scheme

Identical to upstream — an existing `tree.json` produces an identical tree.

| JSON                          | filesystem entry                            |
| ----------------------------- | ------------------------------------------- |
| object                        | directory; keys are entry names             |
| string                        | regular file, contents = the string (0644)  |
| `["link", "target"]`          | symlink → `target`                          |
| `["script", "contents"]`      | executable file, 0755                       |
| anything else                 | hard error, run aborts                      |

Name rules: a single path segment only. `""`, `"."`, `".."`, names
containing `/` and names containing NUL are rejected. Nest objects instead
of using separators.

## Atomicity and security model

**Covered:**

* Symlink at an entry path → replaced, never followed (create with
  `O_NOFOLLOW`, checks with `AT_SYMLINK_NOFOLLOW`, dirs opened `O_NOFOLLOW`).
* Files and symlinks appear atomically via `rename(2)` — no partial
  content, no missing-entry window on replacement.
* Scripts are `chmod`ed to 0755 explicitly, umask-independent.
* `--dry-run` writes nothing, including not creating the target directory.

**Not covered (and not pretended to be):**

* An attacker with write access to the target directory itself can still
  race operations *between* our syscalls. Full TOCTOU-proofing requires
  `openat2(2)`/`RESOLVE_BENEATH` or a mount namespace — out of scope for a
  single-shot CLI, but patches welcome.
* No ownership/UID/GID handling. Run as the user who should own the tree.
* Replacing a **directory** is still delete-then-mkdir — you cannot
  `rename(2)` over a non-empty directory. This is the one operation without
  an atomic path.

## Install

### Nix (everything is a flake)

```console
$ nix profile install github:71g3pf4c3/json2dir-zig
$ nix run github:71g3pf4c3/json2dir-zig -- -n example-tree.json
```

Static musl binaries (Linux, x86_64 and aarch64 — no libc, no runtime, copy
anywhere):

```console
$ nix build github:71g3pf4c3/json2dir-zig#json2dir-static
```

Flake input:

```nix
{
  inputs.json2dir.url = "github:71g3pf4c3/json2dir-zig";
  # packages.${system}.json2dir, .json2dir-static
}
```

Overlay:

```nix
nixpkgs.overlays = [ json2dir.overlays.default ];
environment.systemPackages = [ pkgs.json2dir ];
```

NixOS module:

```nix
imports = [ json2dir.nixosModules.default ];
programs.json2dir.enable = true;
```

home-manager module:

```nix
imports = [ json2dir.homeManagerModules.default ];
programs.json2dir.enable = true;
```

### From source

Any Zig 0.16 toolchain:

```console
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/json2dir -n example-tree.json
```

Or via the devshell: `nix develop` → `zig build test`, `nix fmt`, etc.

## Nix flake outputs

| output                     | what it is                                              |
| -------------------------- | ------------------------------------------------------- |
| `packages.*.json2dir`      | native build for the platform                            |
| `packages.*.json2dir-static` | static musl build (x86_64/aarch64-linux, cross-compiled from any host — Zig needs no cross toolchain) |
| `apps.*.default`           | `nix run`                                                |
| `checks.*`                 | package build + `zig build test` + functional smoke test |
| `devShells.*.default`      | zig, zls, nixfmt                                         |
| `overlays.default`         | adds `pkgs.json2dir`                                     |
| `nixosModules.default`     | `programs.json2dir.enable`                               |
| `homeManagerModules.default` | same option for home-manager                           |
| `formatter`                | `nixfmt`                                                 |

The smoke check runs the **real binary** against a real filesystem: full
materialization (content, modes, symlink targets, script execution),
idempotent rerun, `--no-clobber` refusal, dry-run writing nothing, exit
codes, and a planted `ln -s /` symlink-attack path.

The nix package installs a man page (`json2dir(1)`, rendered with scdoc) and
shell completions (bash, zsh, fish) alongside the binary. Releases (on `v*`
tags) attach fully static tarballs for `x86_64-linux-musl`,
`aarch64-linux-musl` and `aarch64-darwin` — cross-built from a single
linux runner, because that is what Zig is for.

## Development

```console
$ nix develop           # zig 0.16, zls, nixfmt
$ zig build test        # unit tests live in src/manifest.zig
$ zig build run -- -n example-tree.json
$ zig fmt --check .     # zig sources formatted
$ nix flake check       # packages, tests, smoke, modules eval
$ nix fmt               # format the nix files
```

The version lives in exactly one place — `build.zig.zon` — and is threaded
into the binary via build options and into the nix package by parsing the
zon; `nix build` and `json2dir --version` can never disagree.

## What's still not fixed

Honesty section — the remaining sharp edges, in one place:

* **Directory replacement is delete+mkdir.** `rename(2)` cannot land on a
  non-empty directory; there is no atomic swap without `renameat2(RENAME_EXCHANGE)`
  gymnastics. A crash mid-tree leaves a partial tree — but every *completed*
  entry is complete, and no file is ever half-written.
* **No ownership/mode scheme** beyond 0644/0755 and symlinks. If you need
  more, generate a tarball.
* **UTF-8 only**, same as the scheme itself.
* **Duplicate JSON keys**: last one wins (std.json behavior). Generate your
  JSON with a serializer, not `cat`.
* **1 GiB input cap.`** Wanton but generous; a streaming variant is a
  straightforward extension of `std.json.Scanner` if anyone ever hits it.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). This is a clean-room
reimplementation of a publicly documented conversion scheme; it contains no
upstream code.
