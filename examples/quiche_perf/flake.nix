{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
    test-certs.url = "github:birneee/test-certs";
    quiche_perf.url = "github:birneee/quiche_perf";
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
        {
          packages.default = inputs'.nixnet.legacyPackages.mkTestbed {
            workDir = "./out/{}";
            workDirEnsureEmpty = true;
            arp = false;
            arpPrefill = true;
            packages = with pkgs; [
              coreutils
            ];
            namespaces =
              let
                packages = [
                  inputs'.quiche_perf.packages.default
                ];
              in
              {
                client = {
                  inherit packages;
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
                      exec = "QLOGDIR=. RUST_LOG=info quiche-perf client https://10.0.0.2:4433/mem/10MB --cert ${inputs'.test-certs.packages.default}/cert.pem 2> >(tee stderr)";
                      await = true;
                    }
                  ];
                  workDir = "./client";
                };
                server = {
                  inherit packages;
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
                      exec = "QLOGDIR=. RUST_LOG=info quiche-perf server --cert ${inputs'.test-certs.packages.default}/cert.pem --key ${inputs'.test-certs.packages.default}/key.pem 2> >(tee stderr)";
                    }
                  ];
                  workDir = "./server";
                };
              };
            veths = [
              {
                arpPrefill = true;
                arp = false;
                mtu = 1500;
                netem = {
                  rateMbit = 1000;
                  delayMs = 50;
                  autoLimit = true;
                };
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
