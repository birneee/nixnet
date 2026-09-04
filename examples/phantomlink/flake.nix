{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
    phantomlink = {
      url = "github:birneee/phantomlink";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixnet.supportedSystems;
      perSystem =
        { pkgs, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;

          phantomlink = pkgs.callPackage ./phantomlink.nix { src = inputs.phantomlink; };

          pythonWithPlotting = pkgs.python3.withPackages (ps: [ ps.matplotlib ps.pandas ]);

          config = {
            nodePackages = with pkgs; [
              iperf3
              coreutils
            ];
            deterministicMacAddress = true;
            # veths default to checksum offload; PhantomLink resends raw bytes as-is, so disable it
            ethtool = {
              receiveChecksumOffload = false;
              transmitChecksumOffload = false;
              tcpSegmentationOffload = false;
            };
            arp = false;
            arpPrefill = true;
            # runs in the testbed workdir, so the plot lands next to the node dirs;
            # matplotlib needs a writable cache
            postRun = ''
              export MPLCONFIGDIR="$(mktemp -d)"
              ${pythonWithPlotting}/bin/python3 ${./plot.py} client/iperf.json server/iperf.json ${./scenario.csv} plot.pdf
            '';
            nodes = {
              client = {
                # matches PhantomLink's own setup(); link's own sim-veths get promisc from start() itself
                networking.interfaces.veth1 = {
                  link.promiscuous = true;
                  ipv4 = {
                    addresses = [
                      {
                        address = "192.168.22.2";
                        prefixLength = 24;
                      }
                    ];
                    routes = [
                      {
                        address = "0.0.0.0";
                        prefixLength = 0;
                        via = null;
                      }
                    ];
                  };
                };
                scripts.main = {
                  # -J for snd_cwnd, 250 ms sampling as in the paper
                  exec = ''
                    sleep 1
                    iperf3 -c 192.168.66.2 -t 30 -i 0.25 -J > ./iperf.json
                  '';
                  await = true;
                };
              };
              link = {
                # merges the broadcast domain for arpPrefill; no kernel bridge, PhantomLink relays itself
                layer2Transparent = true;
                packages = [
                  phantomlink
                  pkgs.procps
                ];
                # disable privileged PhantomLink features
                scripts.main.exec = ''
                  phantomlink start \
                    --no-max-thread-priority \
                    --no-network-namespace \
                    --no-kernel-params \
                    ${./scenario.csv} 2>&1 | tee ./stdout
                '';
              };
              server = {
                networking.interfaces.veth2 = {
                  link.promiscuous = true;
                  ipv4 = {
                    addresses = [
                      {
                        address = "192.168.66.2";
                        prefixLength = 24;
                      }
                    ];
                    routes = [
                      {
                        address = "0.0.0.0";
                        prefixLength = 0;
                        via = null;
                      }
                    ];
                  };
                };
                # -1 exits after the one client connection, so the JSON closes cleanly
                scripts.main.exec = "iperf3 -s -1 -i 0.25 -J > ./iperf.json";
              };
            };
            veths.veth1 = {
              a = {
                node = "client";
                iface = "veth1";
              };
              b = {
                node = "link";
                iface = "sim-veth1";
              };
            };
            veths.veth2 = {
              a = {
                node = "link";
                iface = "sim-veth2";
              };
              b = {
                node = "server";
                iface = "veth2";
              };
            };
          };
        in
        {
          packages.default = nixnet.mkExperiment config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
