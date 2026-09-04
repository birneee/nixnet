# Helpers shared by the eval tests. Not a test itself: exports functions only,
# so the test runner discovers no derivations here.
{ pkgs }:
let
  lib = pkgs.lib;
in
rec {
  # Evaluate a testbed config, throwing the messages of any unmet assertion.
  evalConfig =
    networkConfig:
    let
      result = lib.evalModules {
        modules = [
          (import ../src/testbed_options.nix {
            inherit pkgs;
            nixpkgs = pkgs.path;
          })
          networkConfig
        ];
      };
      failed = lib.filter (a: !a.assertion) result.config.assertions;
    in
    if failed != [ ] then throw (lib.concatMapStringsSep "\n" (a: a.message) failed) else result;

  # The setup/run script generated for a config.
  mkScript =
    networkConfig:
    (import ../src/testbed_script.nix {
      inherit pkgs;
      config = (evalConfig networkConfig).config;
    }).scriptText;
}
