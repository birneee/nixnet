{ pkgs }:
let
  lib = pkgs.lib;
  linkModule = import ../src/link_options.nix { inherit pkgs; };

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  linkOf = config: node: iface: config.nodes.${node}.networking.interfaces.${iface}.link;

  # interface > veth > global
  cascade =
    (evalConfig {
      link.promiscuous = true;
      veths.eth0 = {
        link.multicast = false;
        a.node = "client";
        b.node = "server";
      };
      nodes.client.networking.interfaces.eth0.link.promiscuous = false;
    }).config;

  extraArgsRejectedAtVeth = builtins.tryEval (
    (evalConfig {
      veths.eth0 = {
        link.extraArgs = [ "group" "100" ];
        a.node = "client";
        b.node = "server";
      };
    }).config.veths.eth0.link
  );

  extraArgsRejectedGlobally = builtins.tryEval (
    (evalConfig { link.extraArgs = [ "group" "100" ]; }).config.link
  );
in
lib.runTests {
  # interface-level wins over veth-level and global
  testInterfaceOverridesAll = {
    expr = (linkOf cascade "client" "eth0").promiscuous;
    expected = false;
  };
  # veth-level wins over global for the other endpoint (no interface-level override there)
  testVethOverridesGlobal = {
    expr = (linkOf cascade "server" "eth0").multicast;
    expected = false;
  };
  # global is the fallback when neither veth nor interface set a field
  testGlobalFallback = {
    expr = (linkOf cascade "server" "eth0").promiscuous;
    expected = true;
  };
  testExtraArgsRejectedAtVethLevel = {
    expr = extraArgsRejectedAtVeth.success;
    expected = false;
  };
  testExtraArgsRejectedGlobally = {
    expr = extraArgsRejectedGlobally.success;
    expected = false;
  };

  # mkCommands: interface value wins per-field, global fills in what's left, extraArgs is interface-only
  testMkCommandsInterfaceWins = {
    expr = linkModule.mkCommands { promiscuous = true; multicast = null; allMulticast = null; trailers = null; transmitQueueLength = null; alias = null; extraArgs = null; } { promiscuous = false; multicast = null; allMulticast = null; trailers = null; transmitQueueLength = null; alias = null; } "veth0";
    expected = [ "link set veth0 promisc on" ];
  };
  testMkCommandsGlobalFallback = {
    expr = linkModule.mkCommands { promiscuous = null; multicast = null; allMulticast = null; trailers = null; transmitQueueLength = null; alias = null; extraArgs = null; } { promiscuous = null; multicast = true; allMulticast = null; trailers = null; transmitQueueLength = null; alias = null; } "veth0";
    expected = [ "link set veth0 multicast on" ];
  };
  testMkCommandsExtraArgs = {
    expr = linkModule.mkCommands { promiscuous = null; multicast = null; allMulticast = null; trailers = null; transmitQueueLength = null; alias = null; extraArgs = [ "group" "100" ]; } { promiscuous = null; multicast = null; allMulticast = null; trailers = null; transmitQueueLength = null; alias = null; } "veth0";
    expected = [ "link set veth0 group 100" ];
  };
}
