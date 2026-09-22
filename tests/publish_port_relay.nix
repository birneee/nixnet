{ pkgs, ... }:
let
  lib = pkgs.lib;

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  freePorts =
    networkConfig:
    map (m: m.freePort) (
      import ../src/testbed_script.nix {
        inherit pkgs;
        config = (evalConfig networkConfig).config;
      }
    ).publishPortMappings;
in
lib.runTests {
  testCountsFromBase = {
    expr = freePorts {
      nodes.a.publishPorts = [ 80 81 ];
    };
    expected = [ 40000 40001 ];
  };
  # testbed serves 40000 itself, relay skips it
  testSkipsTestbedPorts = {
    expr = freePorts {
      publishPorts = [ 40000 ];
      nodes.a.publishPorts = [ 80 81 ];
    };
    expected = [ 40001 40002 ];
  };
}
