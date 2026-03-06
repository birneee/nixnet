{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "path:../..";
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
                scripts = [
                  {
                    exec = "${pkgs.iputils}/bin/ping -c 5 10.0.0.2 > ./stdout 2>&1";
                    await = true;
                  }
                ];
                workDir = "./client";
              };
              ns-server = { };
            };
            links = {
              veth0 = {
                netem = {
                  delayMs = 50;
                };
                a = {
                  ns = "ns-client";
                  ipv4 = "10.0.0.1/24";
                };
                b = {
                  ns = "ns-server";
                  ipv4 = "10.0.0.2/24";
                };
              };
            };
          };
        in
        {
          packages.default = inputs'.nixnet.legacyPackages.mkTestbed config;
          legacyPackages.mermaid = inputs'.nixnet.legacyPackages.mkMermaid config;
        };
    };
}
