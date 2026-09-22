{ pkgs, ... }:
let
  lib = pkgs.lib;

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  accepted = networkConfig: (builtins.tryEval (evalConfig networkConfig).config.assertions).success;
in
lib.runTests {
  testSamePortRejected = {
    expr = accepted {
      publishPorts = [ 8080 ];
      nodes.a.publishPorts = [ { port = 80; hostPort = 8080; } ];
    };
    expected = false;
  };
  # wildcard bind covers the specific address
  testWildcardClashesWithAddress = {
    expr = accepted {
      publishPorts = [ 8080 ];
      nodes.a.publishPorts = [ { port = 80; hostPort = 8080; hostAddr = "127.0.0.1"; } ];
    };
    expected = false;
  };
  testDifferentAddressesAccepted = {
    expr = accepted {
      publishPorts = [ { port = 80; hostPort = 8080; hostAddr = "127.0.0.1"; } ];
      nodes.a.publishPorts = [ { port = 80; hostPort = 8080; hostAddr = "127.0.0.2"; } ];
    };
    expected = true;
  };
  testProtocolsIndependent = {
    expr = accepted {
      publishPorts = [ 53 { port = 53; protocol = "udp"; } ];
    };
    expected = true;
  };
}
