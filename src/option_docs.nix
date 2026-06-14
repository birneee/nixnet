{ pkgs, mkTestbedOptions }:
let
  lib = pkgs.lib;
  optionsDoc =
    (pkgs.nixosOptionsDoc {
      options = (lib.evalModules { modules = [ { options = mkTestbedOptions pkgs; } ]; }).options;
      transformOptions =
        opt:
        opt
        // {
          visible = opt.visible && !(lib.any (lib.hasPrefix "_") (lib.splitString "." opt.name));
        };
    }).optionsCommonMark;
in
pkgs.runCommand "nixnet-option-docs.md" { } ''
  echo "# NixNet Options" > $out
  echo >> $out
  cat ${optionsDoc} >> $out
''
