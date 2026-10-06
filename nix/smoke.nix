{
  lib,
  runCommand,
  json2dir,
}:

runCommand "json2dir-smoke-test"
  {
    meta = {
      description = "Functional smoke test for json2dir-zig";
      platforms = lib.platforms.unix;
    };
  }
  ''
    set -euo pipefail
    cd "$(mktemp -d)"

    exe="${lib.getExe json2dir}"

    cat > tree.json <<'EOF'
    {
      "greeting": "Hello, world!",
      "dir": { "subfile": "Content.\n", "subdir": {} },
      "symlink": ["link", "target path"],
      "script": ["script", "#!/bin/sh\necho Howdy!"]
    }
    EOF

    # 1. basic materialization
    $exe -o out tree.json
    grep -q 'Hello, world!' out/greeting
    grep -qx 'Content\.' out/dir/subfile
    test -d out/dir/subdir
    test "$(readlink out/symlink)" = "target path"
    test "$(./out/script)" = "Howdy!"

    # 2. stdin mode + rerun is idempotent (default force)
    cat tree.json | $exe -o out
    test "$(./out/script)" = "Howdy!"

    # 3. --no-clobber refuses to replace
    if $exe -o out tree.json --no-clobber 2>err.txt; then
      echo "FAIL: --no-clobber run unexpectedly succeeded" >&2
      exit 1
    fi
    grep -q -- '--no-clobber' err.txt

    # 4. --dry-run prints the plan and writes nothing
    $exe -o empty tree.json --dry-run > plan.txt
    test -z "$(ls -A empty 2>/dev/null || true)"
    grep -q 'greeting' plan.txt
    grep -q 'link' plan.txt

    # 5. invalid JSON exits 2
    echo 'not json at all' > bad.json
    set +e
    $exe -o x bad.json 2>/dev/null
    rc=$?
    set -e
    test "$rc" -eq 2

    # 6. bad manifest (path separator in a name) exits 2
    echo '{"a/b": "x"}' > bad2.json
    set +e
    $exe -o x bad2.json 2>/dev/null
    rc=$?
    set -e
    test "$rc" -eq 2

    # 7. usage error exits 1
    set +e
    $exe --wat 2>/dev/null
    rc=$?
    set -e
    test "$rc" -eq 1

    # 8. a pre-existing symlink at an entry path is replaced, not followed
    mkdir -p evil
    ln -s / evil/greeting
    $exe -o evil tree.json
    test "$(cat evil/greeting)" = "Hello, world!"

    touch "$out"
  ''
