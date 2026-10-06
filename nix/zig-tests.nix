{
  lib,
  stdenv,
  zig,
}:

stdenv.mkDerivation {
  pname = "json2dir-unit-tests";
  version = "0.1.0";

  src = ./..;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export HOME="$TMPDIR"

    zig build test \
      --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
      --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
      --summary all

    runHook postBuild
  '';

  installPhase = ''
    touch "$out"
  '';

  meta = {
    description = "Unit tests for json2dir-zig";
    platforms = lib.platforms.unix;
  };
}
