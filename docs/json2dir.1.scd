json2dir(1) "json2dir-zig" "General Commands Manual"

# NAME

json2dir - materialize a JSON document as a directory tree

# SYNOPSIS

*json2dir* [_OPTIONS_] [_FILE_]

# DESCRIPTION

Reads a JSON document (from _FILE_, or standard input when _FILE_ is absent
or *-*) and writes it out as a tree of directories, regular files, symlinks
and executable files. The root of the document must be an object; its keys
become entries of the target directory.

The conversion scheme:

```
object                -> directory (keys are entry names)
string                -> regular file (0644)
["link", target]      -> symlink
["script", contents]  -> executable file (0755)
```

Anything else is a hard error. Entry names must be a single path segment:
"", ".", "..", names containing "/" and names containing NUL are rejected;
nest objects instead of using separators.

Files and symlinks are written under a temporary name and *rename*(2)d into
place, so replacing an entry has no window where it is missing or partially
written, and a run interrupted mid-tree never leaves a truncated file
behind. A pre-existing symlink at an entry path is replaced, never followed:
files are created with O\_CREAT|O\_EXCL, existence and type checks use lstat
semantics, and subdirectories are opened with O\_NOFOLLOW.

# OPTIONS

*-o*, *--out* _DIR_
	Use _DIR_ as the target directory instead of the current one.
	Created on demand for real runs; *--dry-run* does not create it.

*-n*, *--dry-run*
	Validate the whole document and print the plan without touching
	the filesystem. Existing subdirectories are inspected read-only so
	that *--dry-run* combined with *--no-clobber* reports exactly the
	failures a real run would hit.

*-v*, *--verbose*
	Print one line per entry while applying. The plan line format is
	"dir|file|exec|link", the entry path, and, for links, the target;
	entries that replace something existing are suffixed
	"(replacing)". Lines appear in document order.

*--no-clobber*
	Fail instead of replacing existing entries. Off by default:
	replacement is the historical json2dir behavior.

*-h*, *--help*
	Print usage and exit 0.

*-V*, *--version*
	Print version and exit 0.

# EXIT STATUS

0
	Success.

1
	Usage error: unknown option, missing option value, extra operand.

2
	Invalid input: the document is not valid JSON, the root is not an
	object, an entry name is invalid, or *--no-clobber* was requested
	and an entry already exists.

3
	Filesystem error.

Diagnostics are prefixed with the JSON path of the offending entry, e.g.
"json2dir: dir/subdir/x: ...".

# EXAMPLES

Preview, then apply a tree:

```
$ json2dir -n tree.json
$ json2dir -o out tree.json
```

Apply from a pipeline, refusing to clobber:

```
$ jq .files | json2dir -o /srv/app --no-clobber
```

# SEE ALSO

*rename*(2), *symlink*(7)

Project: https://github.com/71g3pf4c3/json2dir-zig
Upstream scheme: https://github.com/alurm/json2dir
