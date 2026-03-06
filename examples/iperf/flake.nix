{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "path:../..";
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
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
            namespaces = {
              ns-client = {
                routes = [
                  {
                    subnet = "10.0.1.0/24";
                    via = "10.0.0.2";
                  }
                ];
                scripts = [
                  {
                    exec = ''
                      sleep 0.1
                      ${pkgs.iperf3}/bin/iperf3 -c 10.0.1.2 > ./stdout 2>&1
                    '';
                    await = true;
                  }
                ];
                workDir = "./client";
              };
              ns-router = {
                ipv4Forward = true;
              };
              ns-server = {
                routes = [
                  {
                    subnet = "10.0.0.0/24";
                    via = "10.0.1.1";
                  }
                ];
                scripts = [
                  { exec = "${pkgs.iperf3}/bin/iperf3 -s > ./stdout 2>&1"; }
                ];
                workDir = "./server";
              };
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
                  ns = "ns-router";
                  ipv4 = "10.0.0.2/24";
                };
              };
              veth1 = {
                a = {
                  ns = "ns-router";
                  ipv4 = "10.0.1.1/24";
                };
                b = {
                  ns = "ns-server";
                  ipv4 = "10.0.1.2/24";
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
