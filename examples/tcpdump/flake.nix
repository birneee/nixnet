{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        { pkgs, inputs', ... }:
        let
          packages = with pkgs; [
            iperf3
            tcpdump
          ];
        in
        {
          packages.default = inputs'.nixnet.legacyPackages.mkTestbed {
            workDir = "out";
            arp = false;
            arpPrefill = true;
            namespaces = {
              client = {
                workDir = "client";
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.0.1";
                      prefixLength = 24;
                    }
                  ];
                };
                scripts = [
                  {
                    inherit packages;
                    exec = ''
                      tcpdump -i veth0 -w iperf.cap &
                      TD_PID=$!
                      cleanup() {
                        kill $TD_PID
                        wait $TD_PID
                      }
                      trap cleanup EXIT
                      sleep 0.1
                      iperf3 -c 10.0.0.2 -t 1 > stdout
                    '';
                    await = true;
                  }
                ];
              };
              server = {
                workDir = "server";
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.0.2";
                      prefixLength = 24;
                    }
                  ];
                };
                scripts = [
                  {
                    inherit packages;
                    exec = ''
                      tcpdump -i veth0 -w iperf.cap &
                      TD_PID=$!
                      cleanup() {
                        kill $TD_PID
                        wait $TD_PID
                      }
                      trap cleanup EXIT
                      iperf -s > stdout
                    '';
                  }
                ];
              };
            };
            veths = [
              {
                a = {
                  ns = "client";
                  iface = "veth0";
                };
                b = {
                  ns = "server";
                  iface = "veth0";
                };
              }
            ];
          };
        };
    };
}
