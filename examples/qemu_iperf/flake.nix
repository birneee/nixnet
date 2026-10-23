{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixnet.supportedSystems;
      perSystem =
        { inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = {
            nodes = {
              client = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                vm =
                  { pkgs, ... }:
                  {
                    virtualisation.cores = 2;
                    environment.systemPackages = [ pkgs.iperf3 ];
                    systemd.services.iperf = nixnet.vmService {
                      # the server VM boots in parallel
                      exec = ''
                        until iperf3 -c 10.0.0.2 > ./stdout 2>&1; do
                          sleep 1
                        done
                      '';
                      await = true;
                    };
                  };
              };
              server = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                vm = {
                  virtualisation.cores = 2;
                  services.iperf3.enable = true;
                };
              };
            };
            veths.eth0 = {
              a.node = "client";
              b.node = "server";
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
