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
              ns-client = {
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                scripts = [
                  {
                    packages = with pkgs; [
                      iputils
                    ];
                    exec = "ping -c 5 10.0.0.2 > ./stdout 2>&1";
                    await = true;
                  }
                ];
                workDir = "./client";
              };
              ns-server = {
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
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
