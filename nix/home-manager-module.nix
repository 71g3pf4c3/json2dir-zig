{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.json2dir;
in
{
  options.programs.json2dir = {
    enable = lib.mkEnableOption "json2dir, a JSON-to-directory-tree materializer";

    package = lib.mkPackageOption pkgs "json2dir" { };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
  };
}
