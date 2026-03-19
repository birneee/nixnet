{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixnet.url = "github:birneee/nixnet";
    starlink.url = "github:birneee/simple-starlink-ebpf";
  };
  outputs =
    inputs@{ nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      nixnet = inputs.nixnet.legacyPackages.${system};
      starlink = inputs.starlink.packages.${system}.default;
    in
    {
      packages.${system}.default = nixnet.mkTestbed {
        packages = with pkgs; [
          coreutils
          iperf3
        ];
        namespaces = {
          client = {
            networking.interfaces.veth0.ipv4.addresses = [
              {
                address = "10.0.0.1";
                prefixLength = 24;
              }
            ];
            postSetup = "ip link set dev veth0 xdp obj ${starlink}/starlink.o sec xdp";
            scripts = [
              {
                exec = "sleep 0.1; iperf3 -c 10.0.0.2 -t 30 --forceflush";
                await = true;
              }
            ];
          };
          server = {
            networking.interfaces.veth0.ipv4.addresses = [
              {
                address = "10.0.0.2";
                prefixLength = 24;
              }
            ];
            postSetup = "ip link set dev veth0 xdp obj ${starlink}/starlink.o sec xdp";
            scripts = [
              {
                exec = "iperf3 -s";
              }
            ];
          };
        };
        veths = [
          {
            netem.delayMs = 40;
            a = {
              ns = "client";
              iface = "veth0";
            };
            b = {
              ns = "server";
              iface = "veth0";
            };
          }
        ];
      };
    };
}
