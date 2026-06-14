{
  pkgs,
  nixpkgs,
}:
let
  lib = pkgs.lib;
  utils = import "${nixpkgs}/nixos/lib/utils.nix" {
    inherit lib pkgs;
    config = { };
  };
  nixosOpts =
    (lib.evalModules {
      modules = [
        "${nixpkgs}/nixos/modules/tasks/network-interfaces.nix"
        { _module.check = false; }
      ];
      specialArgs = { inherit utils pkgs; };
    }).options;

in
lib.types.submodule {
  options = {
    defaultGateway =
      let
        nixosDefaultGateway = nixosOpts.networking.defaultGateway;
      in
      lib.mkOption {
        inherit (nixosDefaultGateway) default description;
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              inherit (nixosDefaultGateway.type.getSubOptions [ ])
                address
                interface
                metric
                source
                ;
            };
          }
        );
      };
    defaultGateway6 =
      let
        nixosDefaultGateway6 = nixosOpts.networking.defaultGateway6;
      in
      lib.mkOption {
        inherit (nixosDefaultGateway6) default description;
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              inherit (nixosDefaultGateway6.type.getSubOptions [ ])
                address
                interface
                metric
                source
                ;
            };
          }
        );
      };
    interfaces =
      let
        nixosInterfaces = nixosOpts.networking.interfaces;
      in
      lib.mkOption {
        default = { };
        inherit (nixosInterfaces) description;
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              ipv4 =
                let
                  nixosIpv4 = (nixosInterfaces.type.getSubOptions [ ]).ipv4;
                in
                {
                  addresses = lib.mkOption {
                    default = [ ];
                    inherit (nixosIpv4.addresses) description;
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          inherit (nixosIpv4.addresses.type.nestedTypes.elemType.getSubOptions [ ]) address prefixLength;
                        };
                      }
                    );
                  };
                  routes = lib.mkOption {
                    default = [ ];
                    inherit (nixosIpv4.routes) description;
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          inherit (nixosIpv4.routes.type.nestedTypes.elemType.getSubOptions [ ])
                            address
                            prefixLength
                            via
                            type
                            options
                            ;
                        };
                      }
                    );
                  };
                };
              ipv6 =
                let
                  nixosIpv6 = (nixosInterfaces.type.getSubOptions [ ]).ipv6;
                in
                {
                  addresses = lib.mkOption {
                    default = [ ];
                    inherit (nixosIpv6.addresses) description;
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          inherit (nixosIpv6.addresses.type.nestedTypes.elemType.getSubOptions [ ]) address prefixLength;
                        };
                      }
                    );
                  };
                  routes = lib.mkOption {
                    default = [ ];
                    inherit (nixosIpv6.routes) description;
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          inherit (nixosIpv6.routes.type.nestedTypes.elemType.getSubOptions [ ])
                            address
                            prefixLength
                            via
                            type
                            options
                            ;
                        };
                      }
                    );
                  };
                };
              mtu =
                let
                  nixosMtu = (nixosInterfaces.type.getSubOptions [ ]).mtu;
                in
                lib.mkOption {
                  inherit (nixosMtu) type default example;
                  description =
                    nixosMtu.description
                    + " Same type as NixOS networking.interfaces.<name>.mtu. Overrides veth-level and top-level mtu.";
                };
              netem = lib.mkOption {
                type = lib.types.nullOr (import ./netem_options.nix { inherit pkgs; });
                default = null;
                description = "netem traffic shaping parameters. Overrides veth-level netem.";
              };
              arp = lib.mkOption {
                type = lib.types.nullOr lib.types.bool;
                default = null;
                description = "Enable ARP on this interface. Overrides veth-level and top-level arp.";
              };
              arpPrefill = lib.mkOption {
                type = lib.types.nullOr lib.types.bool;
                default = null;
                description = "Prefill ARP table with the peer's MAC address. Overrides veth-level and top-level arpPrefill.";
              };
            };
          }
        );
      };
  };
}
