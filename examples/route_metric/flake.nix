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
        { inputs', pkgs, ... }:
        let
          config = {
            workDir = "./out/{}";
            workDirEnsureEmpty = true;
            arp = false;
            arpPrefill = true;
            namespaces = {
              client = {
                networking.interfaces = {
                  eth1.ipv4 = {
                    addresses = [
                      {
                        address = "10.0.1.1";
                        prefixLength = 24;
                      }
                    ];
                    routes = [
                      {
                        address = "10.0.3.0";
                        prefixLength = 24;
                        via = "10.0.1.2";
                        options.metric = "100";
                      }
                    ];
                  };
                  eth2.ipv4 = {
                    addresses = [
                      {
                        address = "10.0.2.1";
                        prefixLength = 24;
                      }
                    ];
                    routes = [
                      {
                        address = "10.0.3.0";
                        prefixLength = 24;
                        via = "10.0.2.2";
                        options.metric = "200";
                      }
                    ];
                  };
                };
                scripts = [
                  {
                    packages = with pkgs; [
                      iputils
                    ];
                    exec = ''
                      ip route show >> ./stdout 2>&1
                      ping -I eth1 -c 3 10.0.3.2 >> ./stdout 2>&1
                      ip link set eth1 down
                      ip route show >> ./stdout 2>&1
                      ping -I eth2 -c 3 10.0.3.2 >> ./stdout 2>&1
                    '';
                    await = true;
                  }
                ];
                workDir = "./client";
              };
              server = {
                networking.interfaces = {
                  eth1.ipv4.addresses = [
                    {
                      address = "10.0.1.2";
                      prefixLength = 24;
                    }
                    {
                      address = "10.0.3.2";
                      prefixLength = 24;
                    }
                  ];
                  eth2.ipv4.addresses = [
                    {
                      address = "10.0.2.2";
                      prefixLength = 24;
                    }
                    {
                      address = "10.0.3.2";
                      prefixLength = 24;
                    }
                  ];
                };
              };
            };
            veths = [
              {
                a = {
                  ns = "client";
                  iface = "eth1";
                };
                b = {
                  ns = "server";
                  iface = "eth1";
                };
              }
              {
                a = {
                  ns = "client";
                  iface = "eth2";
                };
                b = {
                  ns = "server";
                  iface = "eth2";
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
