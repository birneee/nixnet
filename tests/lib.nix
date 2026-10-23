# Helpers shared by the eval tests. Not a test itself: exports functions only,
# so the test runner discovers no derivations here.
{ pkgs }:
let
  lib = pkgs.lib;

  evalUnchecked =
    networkConfig:
    lib.evalModules {
      modules = [
        (import ../src/testbed_options.nix {
          inherit pkgs;
          nixpkgs = pkgs.path;
        })
        networkConfig
      ];
    };
  failedAssertionsOf =
    result: map (a: a.message) (lib.filter (a: !a.assertion) result.config.assertions);
in
rec {
  # Messages of the unmet assertions of a testbed config.
  failedAssertions = networkConfig: failedAssertionsOf (evalUnchecked networkConfig);

  # Evaluate a testbed config, throwing the messages of any unmet assertion.
  evalConfig =
    networkConfig:
    let
      result = evalUnchecked networkConfig;
      failed = failedAssertionsOf result;
    in
    if failed != [ ] then throw (lib.concatStringsSep "\n" failed) else result;

  # The setup/run script generated for a config.
  mkScript =
    networkConfig:
    (import ../src/testbed_script.nix {
      inherit pkgs;
      config = (evalConfig networkConfig).config;
    }).scriptText;
}
