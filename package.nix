{
  lib,
  stdenv,
  zig,
  scdoc,
  installShellFiles,
  zigTarget ? null,
  optimize ? "ReleaseSafe",
}:

let
  # Single source of truth for the version: build.zig.zon.
  version =
    let
      zonText = builtins.readFile ./build.zig.zon;
      versionLine = lib.findFirst (
        line: lib.hasInfix ".version = \"" line
      ) null (lib.splitString "\n" zonText);
    in
    if versionLine == null then
      throw "package.nix: cannot find .version in build.zig.zon"
    else
      lib.head (lib.match ".*\.version = \"([^\"]+)\".*" versionLine);
in
stdenv.mkDerivation {
  pname = "json2dir";
  inherit version;

  src = ./.;

  nativeBuildInputs = [
    zig
    scdoc
    installShellFiles
  ];

  dontConfigure = true;

  # zig build install writes straight into $out via --prefix; the manual
  # is rendered next to it, and the install phase only adds completions.
  buildPhase = ''
    runHook preBuild

    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export HOME="$TMPDIR"

    zig build install \
      --prefix "$out" \
      -Doptimize=${optimize} \
      ${lib.optionalString (zigTarget != null) "-Dtarget=${zigTarget}"} \
      --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
      --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
      --summary all

    mkdir -p "$out/share/man/man1"
    scdoc < docs/json2dir.1.scd > "$out/share/man/man1/json2dir.1"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    installShellCompletion \
      --bash completions/json2dir.bash \
      --zsh completions/_json2dir \
      --fish completions/json2dir.fish
    runHook postInstall
  '';

  meta = {
    description = "Materialize JSON documents as directory trees (Zig rewrite of alurm/json2dir)";
    longDescription = ''
      Reads a JSON document and writes it out as a tree of directories,
      files, symlinks and executables. Drop-in compatible with the
      json2dir conversion scheme, plus --out, --dry-run, --verbose and
      --no-clobber, atomic file placement via rename(2) and O_NOFOLLOW
      hardening against symlink attacks.
    '';
    homepage = "https://github.com/71g3pf4c3/json2dir-zig";
    license = lib.licenses.gpl3Plus;
    mainProgram = "json2dir";
    platforms = lib.platforms.unix;
  };
}
