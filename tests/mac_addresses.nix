{ pkgs }:
let
  lib = pkgs.lib;

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  macOf = config: node: iface: config.nodes.${node}.networking.interfaces.${iface}.macAddress;

  # sequential indices follow veth key order, both endpoints before the next veth
  global =
    (evalConfig {
      deterministicMacAddress = true;
      veths = {
        eth0 = {
          a.node = "client";
          b.node = "server";
        };
        eth1 = {
          a.node = "client";
          b.node = "server";
        };
      };
    }).config;

  # unset by default, kernel assigns at runtime
  kernelAssigned =
    (evalConfig {
      veths.eth0 = {
        a.node = "client";
        b.node = "server";
      };
    }).config;

  # interface > veth > global
  overrides =
    (evalConfig {
      deterministicMacAddress = true;
      veths = {
        eth0 = {
          deterministicMacAddress = false;
          a.node = "client";
          b.node = "server";
        };
        eth1 = {
          a.node = "client";
          b.node = "server";
        };
      };
      nodes.client.networking.interfaces.eth1.macAddress = "02:00:00:aa:bb:cc";
    }).config;

  # deterministic candidate equal to an explicit mac elsewhere
  collision = builtins.tryEval (evalConfig {
    deterministicMacAddress = true;
    veths.eth0 = {
      a.node = "client";
      b.node = "server";
    };
    nodes.server.networking.interfaces.eth0 = {
      macAddress = "02:00:00:00:00:00";
      deterministicMacAddress = false;
    };
  });
in
lib.runTests {
  testGlobalFirstEndpoint = {
    expr = macOf global "client" "eth0";
    expected = "02:00:00:00:00:00";
  };
  testGlobalSecondEndpoint = {
    expr = macOf global "server" "eth0";
    expected = "02:00:00:00:00:01";
  };
  testGlobalNextVeth = {
    expr = macOf global "client" "eth1";
    expected = "02:00:00:00:00:02";
  };
  testKernelAssignedIsNull = {
    expr = macOf kernelAssigned "client" "eth0";
    expected = null;
  };
  # veth-level false wins over global true
  testVethOptOut = {
    expr = macOf overrides "client" "eth0";
    expected = null;
  };
  # explicit macAddress wins over the deterministic default
  testExplicitWins = {
    expr = macOf overrides "client" "eth1";
    expected = "02:00:00:aa:bb:cc";
  };
  # opting one veth out shifts the indices of the rest
  testIndicesSkipOptedOut = {
    expr = macOf overrides "server" "eth1";
    expected = "02:00:00:00:00:01";
  };
  testCollisionRejected = {
    expr = collision.success;
    expected = false;
  };
}
