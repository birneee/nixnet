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
        {
          packages.default = inputs'.nixnet.legacyPackages.mkTestbed {
            workDir = null;
            namespaces = {
              sender = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                scripts = [
                  {
                    exec = ''
                      sleep 0.1
                      ${pkgs.netcat-openbsd}/bin/nc -q 0 10.0.0.2 9000 < ${./msg.txt}
                    '';
                  }
                ];
              };
              receiver = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                scripts = [
                  {
                    exec = "${pkgs.netcat-openbsd}/bin/nc -l -p 9000";
                    await = true;
                  }
                ];
              };
            };
            veths = [
              {
                a = {
                  ns = "sender";
                  iface = "eth0";
                };
                b = {
                  ns = "receiver";
                  iface = "eth0";
                };
              }
            ];
          };
        };
    };
}
