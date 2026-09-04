{ pkgs }:
let
  lib = pkgs.lib;

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  config =
    (evalConfig {
      nodes.client = { };
      nodes.server = { };
      veths.eth0 = {
        a.node = "client";
        b.node = "server";
      };
      veths.link1 = {
        a = {
          node = "client";
          iface = "custom-wan";
        };
        b = {
          node = "server";
          iface = "custom-lan";
        };
      };
    }).config;
in
lib.runTests {
  # veth key is used as default interface name for both endpoints
  testImplicitIfaceA = {
    expr = config.veths.eth0.a.iface;
    expected = "eth0";
  };
  testImplicitIfaceB = {
    expr = config.veths.eth0.b.iface;
    expected = "eth0";
  };
  # explicit iface overrides the key
  testExplicitIfaceA = {
    expr = config.veths.link1.a.iface;
    expected = "custom-wan";
  };
  testExplicitIfaceB = {
    expr = config.veths.link1.b.iface;
    expected = "custom-lan";
  };
}
