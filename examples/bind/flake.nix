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
        { inputs', pkgs, ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config = with nixnet; {
            nodePackages = [
              pkgs.coreutils
              pkgs.file
              (linkFarm "host-tools" [
                {
                  name = "bin/sh";
                  path = hostBind "/bin/sh";
                }
              ])
            ];
            nodes = {
              guest = {
                scripts.main = {
                  exec = ''
                    file ${hostBind "/bin/sh"}
                    file ${pkgs.bash}/bin/sh
                    file $(readlink -f ${pkgs.bash}/bin/sh)
                    file $(command -v sh)
                    file $(readlink -f $(command -v sh))

                    cat ${hostBind "/etc/hostname"} | tee ./hostname.txt
                    cat /etc/hostname | tee ./guestname.txt

                    cat ${roHostBind "/etc/hostname"}

                    echo "Path of read-write file: $(realpath ${hostBind "/etc/hostname"})"
                    echo "Path of read-only file: $(realpath ${roHostBind "/etc/hostname"})"

                    echo "Binding /tmp at $(realpath ${roHostBind "/tmp"})"

                    echo "Trying to create temporary file in read-only /ro-host/tmp (This will fail.)"
                    # Temporily disable exit on non-zero return code
                    set +e
                    # Try to run mktemp - if it succeeds (which it shouldn't), exit script with code 1
                    mktemp -p ${roHostBind "/tmp"} && exit 1
                    set -e

                    cat ${roHostBind ./file.txt}
                  '';
                  await = true;
                };
              };
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
