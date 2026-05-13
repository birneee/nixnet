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
                      ${hostBind "/bin/sh"} -c 'echo hello from host sh'
                      sh -c 'echo hello from host sh via PATH'
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
