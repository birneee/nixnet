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
        { inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = with nixnet; {
            namespaces = {
              a.scripts = [
                {
                  exec = ''
                    echo "hello from a" > ${pipe "ab"}
                  '';
                }
              ];
              b.scripts = [
                {
                  exec = ''
                    cat ${pipe "ab"} > ${pipe "bc"}
                  '';
                }
              ];
              c.scripts = [
                {
                  exec = ''
                    cat ${pipe "bc"}
                  '';
                  await = true;
                }
              ];
            };
          };
        in
        {
          packages.default = nixnet.mkTestbed config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
