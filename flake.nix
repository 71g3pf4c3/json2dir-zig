{
  description = "json2dir rewritten in Zig: JSON documents as directory trees. Static musl binaries, --dry-run, --no-clobber, atomic writes, symlink-attack hardening.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Zig cross-compiles from any host; static musl targets need no
      # cross toolchain, no sysroot, nothing.
      zigStaticTarget = {
        x86_64-linux = "x86_64-linux-musl";
        aarch64-linux = "aarch64-linux-musl";
      };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          json2dir = pkgs.callPackage ./package.nix { };
          default = self.packages.${system}.json2dir;
        }
        // lib.optionalAttrs (builtins.hasAttr system zigStaticTarget) {
          json2dir-static = pkgs.callPackage ./package.nix {
            zigTarget = zigStaticTarget.${system};
          };
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${system}.json2dir;
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) json2dir;
          zig-tests = pkgs.callPackage ./nix/zig-tests.nix { };
          smoke = pkgs.callPackage ./nix/smoke.nix {
            json2dir = self.packages.${system}.json2dir;
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig
              pkgs.zls
              pkgs.nixfmt
            ];
            shellHook = ''
              echo "json2dir-zig devshell (zig $(zig version))"
              echo "  zig build test            run unit tests"
              echo "  zig build run -- -n f.json  dry-run against a JSON file"
              echo "  nix fmt                   format nix files"
            '';
          };
        }
      );

      overlays.default = final: _prev: {
        json2dir = final.callPackage ./package.nix { };
      };

      nixosModules.default = import ./nix/nixos-module.nix;
      homeManagerModules.default = import ./nix/home-manager-module.nix;

      # nixfmt 1.5 deprecated bare (no-argument) invocation; `nix fmt`
      # without paths calls the formatter with zero args, so wrap it:
      # no args = format every .nix file in the tree.
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        pkgs.writeShellScriptBin "nixfmt" ''
          if [ $# -eq 0 ]; then
            find . -name '*.nix' \
              -not -path './.git/*' \
              -not -path './.zig-cache/*' \
              -not -path './result*' \
              -print0 | xargs -0 ${lib.getExe pkgs.nixfmt}
          else
            exec ${lib.getExe pkgs.nixfmt} "$@"
          fi
        ''
      );
    };
}
