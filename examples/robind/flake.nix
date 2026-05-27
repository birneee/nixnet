{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:velix2/nixnet";
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
          nixnet = inputs'.nixnet.legacyPackages;
          config = with nixnet; {
            namespacePackages = [
              pkgs.coreutils
            ];
            namespaces = {
              guest = {
                scripts = [
                  {
                    exec = ''
                      cat ${roHostBind "/etc/hostname"} | tee ./file.txt

                      realpath ${roHostBind "/etc/hostname"}

                      echo "test" > ${hostBind "/dev/null"}
                      realpath ${hostBind "/dev/null"}
                    '';
                    await = true;
                  }
                ];
              };
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
