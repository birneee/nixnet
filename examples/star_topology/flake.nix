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
        {
          pkgs,
          inputs',
          lib,
          ...
        }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          n = 100;
          mkNode = i: {
            nodes.${"node${toString i}"} = {
              packages = with pkgs; [ iputils ];
              networking.interfaces.${"eth${toString i}"}.ipv4.addresses = [
                {
                  address = "10.0.0.${toString i}";
                  prefixLength = 24;
                }
              ];
              scripts.main = {
                exec =
                  let
                    j = (lib.mod i n) + 1;
                    delay = i / 10.0;
                  in
                  ''
                    sleep ${toString delay}
                    ping -c 1 10.0.0.${toString j}
                  '';
                await = true;
              };
            };
            veths.${"eth${toString i}"} = {
              a.node = "node${toString i}";
              b.node = "br0";
            };
          };
          nodeList = map mkNode (lib.range 1 n);
          config = {
            arp = false;
            arpPrefill = true;
            workDir = null;
            bridges = [ "br0" ];
            nodes = lib.mergeAttrsList (map (node: node.nodes) nodeList);
            veths = lib.mergeAttrsList (map (node: node.veths) nodeList);
          };
        in
        {
          packages.default = nixnet.mkExperiment config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
