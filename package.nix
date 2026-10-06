{
  lib,
  stdenv,
  zig,
  zigTarget ? null,
  optimize ? "ReleaseSafe",
}:

stdenv.mkDerivation {
  pname = "json2dir";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;
  dontFixup = true;

  # zig build install writes straight into $out via --prefix; there is
  # nothing left for the standard installPhase to do.
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

    runHook postBuild
  '';

  installPhase = ''
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
