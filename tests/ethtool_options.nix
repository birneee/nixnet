{ pkgs }:
let
  lib = pkgs.lib;
  ethtoolModule = import ../src/ethtool_options.nix { inherit pkgs; };

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  ethtoolOf = config: node: iface: config.nodes.${node}.networking.interfaces.${iface}.ethtool;

  # interface > veth > global
  cascade =
    (evalConfig {
      ethtool.receiveChecksumOffload = true;
      veths.eth0 = {
        ethtool.scatterGather = false;
        a.node = "client";
        b.node = "server";
      };
      nodes.client.networking.interfaces.eth0.ethtool.receiveChecksumOffload = false;
    }).config;

  extraArgsRejectedAtVeth = builtins.tryEval (
    (evalConfig {
      veths.eth0 = {
        ethtool.extraArgs = [ "speed" "1000" ];
        a.node = "client";
        b.node = "server";
      };
    }).config.veths.eth0.ethtool
  );

  extraArgsRejectedGlobally = builtins.tryEval (
    (evalConfig { ethtool.extraArgs = [ "speed" "1000" ]; }).config.ethtool
  );

  ifaceShape = {
    receiveChecksumOffload = null;
    transmitChecksumOffload = null;
    scatterGather = null;
    tcpSegmentationOffload = null;
    udpFragmentationOffload = null;
    genericSegmentationOffload = null;
    genericReceiveOffload = null;
    largeReceiveOffload = null;
    receiveVLANCTAGHardwareAcceleration = null;
    transmitVLANCTAGHardwareAcceleration = null;
    nTupleFilter = null;
    receiveHashingOffload = null;
    rxBufferSize = null;
    rxMiniBufferSize = null;
    rxJumboBufferSize = null;
    txBufferSize = null;
    useAdaptiveRxCoalesce = null;
    useAdaptiveTxCoalesce = null;
    rxCoalesceUsec = null;
    rxMaxCoalescedFrames = null;
    txCoalesceUsec = null;
    txMaxCoalescedFrames = null;
    autoNegotiationFlowControl = null;
    rxFlowControl = null;
    txFlowControl = null;
  };
  globalShape = builtins.removeAttrs ifaceShape [ ];
in
lib.runTests {
  # interface-level wins over veth-level and global
  testInterfaceOverridesAll = {
    expr = (ethtoolOf cascade "client" "eth0").receiveChecksumOffload;
    expected = false;
  };
  # veth-level wins over global for the other endpoint (no interface-level override there)
  testVethOverridesGlobal = {
    expr = (ethtoolOf cascade "server" "eth0").scatterGather;
    expected = false;
  };
  # global is the fallback when neither veth nor interface set a field
  testGlobalFallback = {
    expr = (ethtoolOf cascade "server" "eth0").receiveChecksumOffload;
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

  # mkCommands: one -K call per feature (batched, a single refused feature would
  # not fail), here an interface override plus a global fallback
  testMkCommandsOneOffloadCallPerFeature = {
    expr = ethtoolModule.mkCommands (ifaceShape // { tcpSegmentationOffload = false; extraArgs = null; }) (
      globalShape // { receiveChecksumOffload = false; }
    ) "veth0";
    expected = [
      "ethtool -K veth0 rx off > /dev/null"
      "ethtool -K veth0 tso off > /dev/null"
    ];
  };
  testMkCommandsRing = {
    expr = ethtoolModule.mkCommands (ifaceShape // { rxBufferSize = 512; extraArgs = null; }) globalShape "veth0";
    expected = [ "ethtool -G veth0 rx 512 > /dev/null" ];
  };
  testMkCommandsExtraArgs = {
    expr = ethtoolModule.mkCommands (ifaceShape // { extraArgs = [ "speed" "1000" ]; }) globalShape "veth0";
    expected = [ "ethtool veth0 speed 1000 > /dev/null" ];
  };
}
