{ pkgs }:
let
  lib = pkgs.lib;
  inherit (import ../src/common.nix { inherit pkgs; }) mkRemovedOptionModule removedOptionAssertion;

  assertionsOf =
    config:
    (lib.evalModules {
      modules = [
        { options.assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; }; }
        (mkRemovedOptionModule "old" "has been renamed to `new`")
        config
      ];
    }).config.assertions;
in
lib.runTests {
  testUnsetPasses = {
    expr = (removedOptionAssertion "a.old" null "has been removed").assertion;
    expected = true;
  };
  testSetFails = {
    expr = removedOptionAssertion "a.old" 1 "has been removed";
    expected = {
      assertion = false;
      message = "nixnet: `a.old` has been removed";
    };
  };
  testModuleUnsetPasses = {
    expr = map (a: a.assertion) (assertionsOf { });
    expected = [ true ];
  };
  testModuleSetFails = {
    expr = assertionsOf { old = 1; };
    expected = [
      {
        assertion = false;
        message = "nixnet: `old` has been renamed to `new`";
      }
    ];
  };
}
