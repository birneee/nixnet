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
          config = {
            workDir = "./out/{}";
            workDirEnsureEmpty = true;
            arp = false;
            arpPrefill = true;
            packages = with pkgs; [
              coreutils
              iperf3
            ];
            namespaces = {
              ns-client = {
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.0.1";
                      prefixLength = 24;
                    }
                  ];
                  routes = [
                    {
                      address = "10.0.1.0";
                      prefixLength = 24;
                      via = "10.0.0.2";
                    }
                  ];
                };
                scripts = [
                  {
                    exec = ''
                      sleep 0.1
                      iperf3 -c 10.0.1.2 > ./stdout 2>&1
                    '';
                    await = true;
                  }
                ];
                workDir = "./client";
              };
              ns-router = {
                networking.interfaces = {
                  veth0.ipv4.addresses = [
                    {
                      address = "10.0.0.2";
                      prefixLength = 24;
                    }
                  ];
                  veth1.ipv4.addresses = [
                    {
                      address = "10.0.1.1";
                      prefixLength = 24;
                    }
                  ];
                };
                sysctl."net.ipv4.ip_forward" = true;
              };
              ns-server = {
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "10.0.1.2";
                      prefixLength = 24;
                    }
                  ];
                  routes = [
                    {
                      address = "10.0.0.0";
                      prefixLength = 24;
                      via = "10.0.1.1";
                    }
                  ];
                };
                scripts = [
                  { exec = "iperf3 -s > ./stdout 2>&1"; }
                ];
                workDir = "./server";
              };
            };
            veths = [
              {
                netem.delayMs = 50;
                a = {
                  ns = "ns-client";
                  iface = "veth0";
                };
                b = {
                  ns = "ns-router";
                  iface = "veth0";
                };
              }
              {
                a = {
                  ns = "ns-router";
                  iface = "veth1";
                };
                b = {
                  ns = "ns-server";
                  iface = "veth0";
                };
              }
            ];
          };
        in
        {
          packages.default = inputs'.nixnet.legacyPackages.mkTestbed config;
          legacyPackages.mermaid = inputs'.nixnet.legacyPackages.mkMermaid config;
        };
    };
}
