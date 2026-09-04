{ pkgs }:
let
  lib = pkgs.lib;

  inherit (import ./lib.nix { inherit pkgs; }) mkScript;

  # client <-veth1-> relay <-veth2-> server, relay relaying frames itself
  # (like a userspace L2 relay) rather than being a kernel bridge.
  mkConfig =
    layer2Transparent:
    let
      endpoint = ip: {
        arp = false;
        arpPrefill = true;
        ipv4.addresses = [
          {
            address = ip;
            prefixLength = 24;
          }
        ];
      };
    in
    {
      deterministicMacAddress = true;
      nodes = {
        client.networking.interfaces.veth1 = endpoint "192.168.22.2";
        relay = {
          inherit layer2Transparent;
          networking.interfaces = {
            simveth1.ipv4.addresses = [
              {
                address = "192.168.33.2";
                prefixLength = 24;
              }
            ];
            simveth2.ipv4.addresses = [
              {
                address = "192.168.33.3";
                prefixLength = 24;
              }
            ];
          };
        };
        server.networking.interfaces.veth2 = endpoint "192.168.66.2";
      };
      veths.veth1 = {
        a = {
          node = "client";
          iface = "veth1";
        };
        b = {
          node = "relay";
          iface = "simveth1";
        };
      };
      veths.veth2 = {
        a = {
          node = "relay";
          iface = "simveth2";
        };
        b = {
          node = "server";
          iface = "veth2";
        };
      };
    };

  withoutLayer2Transparent = mkScript (mkConfig false);
  withLayer2Transparent = mkScript (mkConfig true);
in
lib.runTests {
  # without layer2Transparent, client and server sit in separate 2-member domains: a
  # domain listing both their addresses (adjacent lines, same table) never
  # appears, so arpPrefill only ever resolves the direct veth peer (relay's
  # own interface), never the actual remote endpoint reached by relaying
  # through it.
  testWithoutLayer2TransparentNoSharedDomain = {
    expr = lib.hasInfix "neigh add 192.168.22.2 lladdr 02:00:00:00:00:00 dev %DEV%\n\tneigh add 192.168.66.2" withoutLayer2Transparent;
    expected = false;
  };
  # with layer2Transparent, client/relay/server are merged into one domain: arpPrefill
  # resolves the real remote MAC directly on both sides.
  testWithLayer2TransparentResolvesRemote = {
    expr = lib.hasInfix "neigh add 192.168.66.2 lladdr 02:00:00:00:00:03" withLayer2Transparent;
    expected = true;
  };
  testWithLayer2TransparentResolvesRemoteOtherWay = {
    expr = lib.hasInfix "neigh add 192.168.22.2 lladdr 02:00:00:00:00:00" withLayer2Transparent;
    expected = true;
  };
  # layer2Transparent doesn't create a kernel bridge device or attach interfaces via master
  testLayer2TransparentNoMasterAttach = {
    expr = lib.hasInfix "master relay" withLayer2Transparent;
    expected = false;
  };
}
