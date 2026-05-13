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
          nixnet = inputs'.nixnet.legacyPackages;
          config = with nixnet; {
            namespacePackages = [
              pkgs.coreutils
              pkgs.file
              (linkFarm "host-tools" [
                {
                  name = "bin/sh";
                  path = hostBind "/bin/sh";
                }
              ])
            ];
            namespaces = {
              guest = {
                scripts = [
                  {
                    exec = ''
                      file ${hostBind "/bin/sh"}
                      file ${pkgs.bash}/bin/sh
                      file $(readlink -f ${pkgs.bash}/bin/sh)
                      file $(command -v sh)
                      file $(readlink -f $(command -v sh))
                      
                      cat ${hostBind "/etc/hostname"} | tee ./hostname.txt
                      cat /etc/hostname | tee ./guestname.txt
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
