{ pkgs }:
let
  lib = pkgs.lib;

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig mkScript;
  vmLib = import ../src/vm.nix { inherit pkgs; };

  # client runs a VM, server is a plain node
  networkConfig = {
    nodes = {
      client = {
        networking = {
          interfaces.eth0 = {
            ipv4.addresses = [
              {
                address = "10.0.0.1";
                prefixLength = 24;
              }
            ];
            mtu = 9000;
          };
          defaultGateway.address = "10.0.0.2";
        };
        vm.systemd.services = {
          ping = vmLib.vmService {
            exec = "ping -c 1 10.0.0.2";
            await = true;
          };
          # not awaited, never run by the tests
          capture = vmLib.vmService { exec = "tcpdump -i eth0"; };
        };
      };
      server.networking.interfaces.eth0 = {
        ipv4.addresses = [
          {
            address = "10.0.0.2";
            prefixLength = 24;
          }
        ];
        arpPrefill = true;
      };
    };
    veths.eth0 = {
      a.node = "client";
      b.node = "server";
    };
  };
  config = (evalConfig networkConfig).config;
  script = mkScript networkConfig;
  # the client VM's script and NixOS configuration
  vmScript = (vmLib.mkVm "client" config.nodes.client).script;
  vmConfig = (vmLib.mkSystem "client" config.nodes.client).config;

  # `extra` with a VM node with n interfaces, each on a veth to a plain node
  evalWithInterfaces =
    n: extra:
    evalConfig {
      imports = [ extra ];
      nodes.client.vm = { };
      veths = lib.genAttrs (map (i: "eth${toString i}") (lib.range 1 n)) (_: {
        a.node = "client";
        b.node = "server";
      });
    };
  twoInterfacesVm = evalWithInterfaces 2 { };
  # whether it passes the assertions
  acceptedWithInterfaces =
    n: extra: (builtins.tryEval (evalWithInterfaces n extra).config.assertions).success;
in
lib.runTests {
  # launched like a background script, but none of the node's
  testVmLaunchedAwaited = {
    expr = lib.hasInfix "nodes/client/vm" script && lib.hasInfix "WAIT_PIDS[$!]=1" script;
    expected = true;
  };
  testVmNotAScript = {
    expr = config.nodes.client.scripts;
    expected = { };
  };
  testVmConsoleToLog = {
    expr = lib.hasInfix "> qemu.log" vmScript;
    expected = true;
  };
  testVmWiresEveryInterface = {
    expr =
      lib.all
        (
          tap:
          lib.hasInfix "redirect dev ${tap}" (vmLib.mkVm "client" twoInterfacesVm.config.nodes.client).script
        )
        [
          "vmtap0"
          "vmtap1"
        ];
    expected = true;
  };
  # the VM's addresses and routes are configured in the VM, not its node
  testVmNodeNotAddressed = {
    expr = lib.hasInfix "addr add 10.0.0.1/24" script;
    expected = false;
  };
  testPlainNodeAddressed = {
    expr = lib.hasInfix "addr add 10.0.0.2/24" script;
    expected = true;
  };
  testVmNodeNotRouted = {
    expr = lib.hasInfix "route add default via 10.0.0.2" script;
    expected = false;
  };
  testPlainNodeArpPrefill = {
    expr = lib.hasInfix "ip -n server -b - <<<" script;
    expected = true;
  };
  # no sysctl in a VM node's namespace, neither the top-level's nor nixnet's own
  testVmNodeNoSysctl = {
    expr = lib.hasInfix "ip netns exec client sysctl" script;
    expected = false;
  };
  testPlainNodeSysctl = {
    expr = lib.hasInfix "ip netns exec server sysctl" script;
    expected = true;
  };
  testVmWithoutInterfaces = {
    expr =
      let
        solo = (evalConfig { nodes.solo.vm = { }; }).config;
      in
      lib.hasInfix "run-solo-vm" (vmLib.mkVm "solo" solo.nodes.solo).script;
    expected = true;
  };
  # one PCI slot per NIC
  testVmFitsSixteenInterfaces = {
    expr = acceptedWithInterfaces 16 { };
    expected = true;
  };
  testVmRejectsSeventeenInterfaces = {
    expr = acceptedWithInterfaces 17 { };
    expected = false;
  };
  # networkd needs a gateway's interface, guessed only for a single one
  testVmRejectsUnboundGatewayOfSeveralInterfaces = {
    expr = acceptedWithInterfaces 2 { nodes.client.networking.defaultGateway6.address = "fd00::1"; };
    expected = false;
  };
  testVmAcceptsBoundGatewayOfSeveralInterfaces = {
    expr = acceptedWithInterfaces 2 {
      nodes.client.networking.defaultGateway6 = {
        address = "fd00::1";
        interface = "eth1";
      };
    };
    expected = true;
  };
  # any option without an effect on the VM is rejected
  testVmAcceptsCompatibleOptions = {
    expr = acceptedWithInterfaces 1 {
      nodes.client = {
        networking.interfaces.eth1 = {
          mtu = 9000;
          macAddress = "02:00:00:00:00:01";
          netem.delayMs = 10;
        };
      };
    };
    expected = true;
  };
  # a VM node is a VM, not a sandbox
  testVmRejectsScripts = {
    expr = acceptedWithInterfaces 1 { nodes.client.scripts.capture.exec = "tcpdump -i eth1"; };
    expected = false;
  };
  # in the VM's own boot.kernel.sysctl instead
  testVmRejectsSysctl = {
    expr = acceptedWithInterfaces 1 { nodes.client.sysctl."net.ipv4.tcp_congestion_control" = "bbr"; };
    expected = false;
  };
  testVmRejectsPackages = {
    expr = acceptedWithInterfaces 1 { nodes.client.packages = [ pkgs.tcpdump ]; };
    expected = false;
  };
  testVmRejectsPreSetup = {
    expr = acceptedWithInterfaces 1 { nodes.client.preSetup = "true"; };
    expected = false;
  };
  testVmRejectsShareWayland = {
    expr = acceptedWithInterfaces 1 { nodes.client.shareWayland = true; };
    expected = false;
  };
  testVmRejectsInterfaceArp = {
    expr = acceptedWithInterfaces 1 { nodes.client.networking.interfaces.eth1.arp = false; };
    expected = false;
  };
  testVmRejectsArpPrefill = {
    expr = acceptedWithInterfaces 1 { nodes.client.networking.interfaces.eth1.arpPrefill = true; };
    expected = false;
  };
  testVmRejectsInterfaceLink = {
    expr = acceptedWithInterfaces 1 {
      nodes.client.networking.interfaces.eth1.link.promiscuous = true;
    };
    expected = false;
  };
  testVmRejectsInterfaceEthtool = {
    expr = acceptedWithInterfaces 1 {
      nodes.client.networking.interfaces.eth1.ethtool.tcpSegmentationOffload = false;
    };
    expected = false;
  };
  # top-level and veth settings reach the VM's interfaces too, unless they override them
  testVmRejectsTopLevelArp = {
    expr = acceptedWithInterfaces 1 { arp = false; };
    expected = false;
  };
  testVmAcceptsOverriddenTopLevelArp = {
    expr = acceptedWithInterfaces 1 {
      arp = false;
      nodes.client.networking.interfaces.eth1.arp = true;
    };
    expected = true;
  };
  testVmNodeGetsDevices = {
    expr = lib.all (dev: lib.hasInfix "--bind ${dev} ${dev}" script) [
      "/dev/net/tun"
      "/dev/vhost-net"
      "/dev/kvm"
    ];
    expected = true;
  };

  # the VM's NixOS configuration
  testVmGuessesGatewayInterface = {
    expr = vmConfig.networking.defaultGateway.interface;
    expected = "eth0";
  };
  testVmGetsAddresses = {
    expr = map (a: a.address) vmConfig.networking.interfaces.eth0.ipv4.addresses;
    expected = [ "10.0.0.1" ];
  };
  testVmNamesNicAfterInterface = {
    expr = { inherit (vmConfig.systemd.network.links.eth0) matchConfig linkConfig; };
    expected = {
      matchConfig.Path = "pci-0000:00:10.0";
      linkConfig = {
        Name = "eth0";
        MTUBytes = "9000";
      };
    };
  };
  # in the node's workDir, like a node script
  testVmServiceInWorkDir = {
    expr = vmConfig.systemd.services.ping.serviceConfig.WorkingDirectory;
    expected = "/pwd";
  };
  # powers off after the awaited services only
  testVmPowersOffAfterAwaited = {
    expr = vmConfig.systemd.services.nixnet-poweroff.after;
    expected = [ "ping.service" ];
  };
  testVmPowersOffAfterAllAwaited = {
    expr =
      let
        twoAwaited =
          (evalWithInterfaces 1 {
            nodes.client.vm.systemd.services = lib.genAttrs [ "a" "b" ] (
              _:
              vmLib.vmService {
                exec = "true";
                await = true;
              }
            );
          }).config;
      in
      (vmLib.mkSystem "client" twoAwaited.nodes.client).config.systemd.services.nixnet-poweroff.after;
    expected = [
      "a.service"
      "b.service"
    ];
  };
  testVmWithoutAwaitedNotAwaited = {
    expr = (vmLib.mkVm "client" twoInterfacesVm.config.nodes.client).awaited;
    expected = false;
  };
  # the awaited services' exit status, passed on by the VM's script
  testVmPassesOnExitStatus = {
    expr = lib.hasInfix "xchg/exit-status" vmScript;
    expected = true;
  };
  # a failed boot ends the VM instead of hanging
  testVmPanicsOnFailedBoot = {
    expr = lib.all (param: lib.elem param vmConfig.boot.kernelParams) [
      "panic=1"
      "boot.panic_on_fail"
    ];
    expected = true;
  };
  testVmQemuDoesNotReboot = {
    expr = lib.elem "-no-reboot" vmConfig.virtualisation.qemu.options;
    expected = true;
  };
  testVmFailsWithoutExitStatus = {
    expr = lib.hasInfix "ended before its awaited services finished" vmScript;
    expected = true;
  };
  # sorts before the NICs' link files, it would apply instead
  testVmMasksDefaultLink = {
    expr = vmConfig.environment.etc."systemd/network/99-default.link".source;
    expected = "/dev/null";
  };
}
