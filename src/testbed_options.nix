{ pkgs, nixpkgs }:
{ config, ... }:
let
  lib = pkgs.lib;
  nixosOpts =
    let
      utils = import "${nixpkgs}/nixos/lib/utils.nix" {
        inherit lib pkgs;
        config = { };
      };
    in
    (lib.evalModules {
      modules = [
        "${nixpkgs}/nixos/modules/config/sysctl.nix"
        "${nixpkgs}/nixos/modules/tasks/network-interfaces.nix"
        { _module.check = false; }
      ];
      specialArgs = { inherit utils pkgs; };
    }).options;

  nixosSysctlOption = nixosOpts.boot.kernel.sysctl;
  netem = import ./netem_options.nix { inherit pkgs; };
  linkModule = import ./link_options.nix { inherit pkgs; };
  ethtoolModule = import ./ethtool_options.nix { inherit pkgs; };
  inherit (import ./common.nix { inherit pkgs; }) attrsOrLegacyList busyboxMini resolveFirst;

  iface = lib.types.submodule {
    options = {
      ns = lib.mkOption {
        visible = false;
        default = null;
        type = lib.types.nullOr lib.types.str;
      };
      node = lib.mkOption {
        type = lib.types.str;
        description = "Node or bridge for this endpoint.";
      };
      iface = lib.mkOption {
        type = lib.types.str;
        description = "Interface name within the node.";
      };
    };
  };

in
{
  options = {
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      visible = false;
    };
    nodes = lib.mkOption {
      default = { };
      description = "Network nodes (namespaces) to create.";
      type = lib.types.attrsOf (import ./node_options.nix { inherit pkgs nixpkgs nixosSysctlOption; });
    };

    veths = lib.mkOption {
      default = { };
      apply =
        val:
        if builtins.isList val then
          throw "nixnet: `veths` is now an attrset — use `veths.<name> = { a.node = ...; b.node = ...; }`"
        else
          val;
      type = attrsOrLegacyList (
        lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }: {
              options = {
                netem = lib.mkOption {
                  type = lib.types.nullOr netem;
                  default = null;
                  description = "netem traffic shaping parameters applied to both endpoints. Individual fields can be overridden per interface via networking.interfaces.";
                };
                arp = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable ARP for both endpoints of this veth pair. Overrides top-level arp.";
                };
                arpPrefill = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Prefill ARP table for both endpoints of this veth pair. Overrides top-level arpPrefill.";
                };
                deterministicMacAddress = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Compute both endpoints' MAC addresses deterministically during nix evaluation instead of leaving it to the kernel at runtime. Overrides top-level deterministicMacAddress. Ignored for an endpoint whose interface sets macAddress explicitly.";
                };
                link = lib.mkOption {
                  type = linkModule.cascadeType;
                  default = { };
                  description = "Direct mappings of `ip link set` flags (see ip-link(8)) for both endpoints of this veth pair. Each field overrides top-level link settings individually; overridden per-field by the interface-level link option. extraArgs is interface-level only.";
                };
                ethtool = lib.mkOption {
                  type = ethtoolModule.cascadeType;
                  default = { };
                  description = "Direct mappings of `ethtool` settings (see ethtool(8)) for both endpoints of this veth pair. Each field overrides top-level ethtool settings individually; overridden per-field by the interface-level ethtool option. extraArgs is interface-level only.";
                };
                mtu =
                  let
                    nixosMtu = (nixosOpts.networking.interfaces.type.nestedTypes.elemType.getSubOptions [ ]).mtu;
                  in
                  lib.mkOption {
                    inherit (nixosMtu) type default example;
                    description =
                      nixosMtu.description
                      + " Same type as NixOS networking.interfaces.<name>.mtu. Overrides top-level mtu.";
                  };
                a = lib.mkOption {
                  type = iface;
                  description = "First endpoint of this veth pair.";
                };
                b = lib.mkOption {
                  type = iface;
                  description = "Second endpoint of this veth pair.";
                };
              };
              config = {
                a.iface = lib.mkDefault name;
                b.iface = lib.mkDefault name;
              };
            }
          )
        )
      );
      description = "veth pairs to create between nodes. The attribute key is used as the default interface name.";
    };

    bridges = lib.mkOption {
      default = [ ];
      type = lib.types.listOf lib.types.str;
      description = "Bridges to create. Each bridge gets its own node of the same name.";
    };

    arp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Global default ARP setting for all interfaces.";
    };
    arpPrefill = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Global default arpPrefill setting for all interfaces.";
    };
    deterministicMacAddress = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Global default deterministicMacAddress setting for all interfaces. When enabled, MAC addresses are computed during nix evaluation (from node and interface name) instead of being assigned randomly by the kernel at runtime, so arpPrefill can embed them directly instead of reading them back at runtime.";
    };
    link = lib.mkOption {
      type = linkModule.cascadeType;
      default = { };
      description = "Global default `ip link set` flags (see ip-link(8)) for all interfaces. Each field is overridden per-field by veth-level and then interface-level link settings. extraArgs is interface-level only.";
    };
    ethtool = lib.mkOption {
      type = ethtoolModule.cascadeType;
      default = { };
      description = "Global default `ethtool` settings (see ethtool(8)) for all interfaces. Each field is overridden per-field by veth-level and then interface-level ethtool settings. extraArgs is interface-level only.";
    };
    mtu =
      let
        nixosMtu = (nixosOpts.networking.interfaces.type.nestedTypes.elemType.getSubOptions [ ]).mtu;
      in
      lib.mkOption {
        inherit (nixosMtu) type default example;
        description =
          nixosMtu.description
          + " Same type as NixOS networking.interfaces.<name>.mtu. Global default for all interfaces. Can be overridden per veth via veths.*.mtu or per interface via networking.interfaces.<name>.mtu.";
      };
    workDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "out/{run}";
      description = "Working directory for the testbed. Created if absent. \`{run}\` is replaced at runtime with a two-digit zero-padded run index (default \`00\`), e.g. with \`nix run . 5\` uses \`out/05\`. Pass a range to run multiple times: \`nix run . 1-5\`.";
    };
    workDirEnsureEmpty = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Abort if workDir exists and is not empty, preventing existing results from being overwritten.";
    };
    nodePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        busyboxMini
        bashNonInteractive
        coreutils
        iproute2
        util-linuxMinimal
      ];
      description = "Packages prepended to PATH for all nodes. Lower priority than node-level packages. Defaults to a set of standard tools; extend with \`lib.mkOptionDefault [ yourPkg ]\`.";
    };
    testbedPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        busyboxMini
        bashNonInteractive
        coreutils
        iproute2
        util-linuxMinimal
        ethtool
      ];
      description = "Packages prepended to PATH for testbed hooks (preSetup, postSetup, preRun, postRun) and testbed-level scripts. Defaults to a set of standard tools; extend with \`lib.mkOptionDefault [ yourPkg ]\`.";
    };
    sysctl = nixosSysctlOption // {
      description = nixosSysctlOption.description + " Can be overridden per node.";
    };
    shareWayland = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Bind the Wayland display socket and graphics devices into the sandbox, enabling GUI applications.";
    };
    sharePipeWire = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Bind the PipeWire and PulseAudio-compat sockets into the sandbox, enabling audio output.";
    };
    preSetup = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run before the setup phase (before nodes and links are created). Runs as root.";
    };
    postSetup = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run after the setup phase (after nodes, links, and routes are configured). Runs as root.";
    };
    preRun = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run before the run phase (before scripts are launched). Runs as root.";
    };
    postRun = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run after the run phase (after all awaited scripts have exited). Runs as root.";
    };
    scripts = lib.mkOption {
      default = { };
      apply =
        val:
        if builtins.isList val then
          throw "nixnet: `scripts` is now an attrset — use `scripts.<name> = { exec = ...; }`"
        else
          val;
      type = attrsOrLegacyList (
        lib.types.attrsOf (
          lib.types.submodule {
            options = {
              exec = lib.mkOption {
                type = lib.types.str;
                example = lib.literalExpression ''
                  ''''
                    ''${pkgs.curl}/bin/curl https://example.com
                    cat ''${nixnet.hostBind "/etc/os-release"}
                  ''''
                '';
                description = "Script to run in the testbed context (outside any node). May be multi-line.";
              };
              foreground = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Run this script in the foreground without output redirection. Runs after all background scripts are started. Use for interactive shells or tools that require a terminal.";
              };
              await = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Wait for this script to finish before stopping the testbed. Only applies to background scripts.";
              };
            };
          }
        )
      );
      description = "Scripts to run in the testbed context (outside any node). Background scripts are launched in parallel with node scripts; foreground scripts run sequentially after all background scripts are started. The attribute key is used as the script filename.";
    };
    name = lib.mkOption {
      type = lib.types.str;
      default = "testbed";
      description = "Name of the experiment, used as the derivation's package name (e.g. its Nix store path prefix) and as a filename prefix for generated node/testbed script files. The public entry point users run is always $out/bin/0-clear regardless of this value.";
    };
  };

  config =
    let
      vethList = lib.attrValues config.veths;
      getVeth =
        nodeName: ifaceName:
        lib.findFirst (
          v:
          (v.a.node == nodeName && v.a.iface == ifaceName) || (v.b.node == nodeName && v.b.iface == ifaceName)
        ) null vethList;
      allVethEndpoints = lib.concatMap (v: [ v.a v.b ]) vethList;
      macKey = endpoint: "${endpoint.node}:${endpoint.iface}";

      # deterministic macAddress, mkDefault below (interface > veth > global)
      mkSequentialMacAddress =
        index:
        let
          octet = n: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (lib.mod n 256)));
          rest = index / 256;
        in
        "02:00:00:" + lib.concatStringsSep ":" (map octet [ (rest / 256) rest index ]);
      wantsDeterministicMac =
        endpoint:
        resolveFirst "deterministicMacAddress" [
          config.nodes.${endpoint.node}.networking.interfaces.${endpoint.iface}
          (getVeth endpoint.node endpoint.iface)
          config
        ];
      deterministicEndpoints = lib.filter wantsDeterministicMac allVethEndpoints;
      deterministicMacAddresses = lib.listToAttrs (
        lib.imap0 (i: endpoint: {
          name = macKey endpoint;
          value = mkSequentialMacAddress i;
        }) deterministicEndpoints
      );

    in
    {
      nodes = lib.foldl' lib.recursiveUpdate { } (
        map (
          endpoint:
          let
            veth = getVeth endpoint.node endpoint.iface;
          in
          lib.setAttrByPath [ endpoint.node "networking" "interfaces" endpoint.iface ] {
            mtu = lib.mkDefault (resolveFirst "mtu" [ veth config ]);
            arp = lib.mkDefault (resolveFirst "arp" [ veth config ]);
            arpPrefill = lib.mkDefault (resolveFirst "arpPrefill" [ veth config ]);
            macAddress = lib.mkDefault (deterministicMacAddresses.${macKey endpoint} or null);
            link = lib.genAttrs linkModule.fieldNames (
              field: lib.mkDefault (resolveFirst field [ veth.link config.link ])
            );
            ethtool = lib.genAttrs ethtoolModule.fieldNames (
              field: lib.mkDefault (resolveFirst field [ veth.ethtool config.ethtool ])
            );
          }
        ) allVethEndpoints
      );
      assertions =
        let
          # deterministic collisions only, matching explicit macs are the user's choice.
          # unique indices, so a match is always against an explicit mac
          collidesElsewhere =
            endpoint: candidate:
            lib.any (
              other:
              !(other.node == endpoint.node && other.iface == endpoint.iface)
              && config.nodes.${other.node}.networking.interfaces.${other.iface}.macAddress == candidate
            ) allVethEndpoints;
          deterministicCollisions = lib.filter (m: m != null) (
            map (
              endpoint:
              let
                candidate = deterministicMacAddresses.${macKey endpoint} or null;
              in
              if candidate != null && collidesElsewhere endpoint candidate then candidate else null
            ) deterministicEndpoints
          );
          renamedNsAssertions = lib.concatLists (
            lib.mapAttrsToList (vethName: veth: [
              {
                assertion = veth.a.ns == null;
                message = "nixnet: `veths.${vethName}.a.ns` renamed to `node`";
              }
              {
                assertion = veth.b.ns == null;
                message = "nixnet: `veths.${vethName}.b.ns` renamed to `node`";
              }
            ]) config.veths
          );
        in
        [
          {
            assertion = deterministicCollisions == [ ];
            message = "nixnet: deterministicMacAddress collision: ${lib.concatStringsSep ", " deterministicCollisions} — set macAddress explicitly to resolve";
          }
        ]
        ++ renamedNsAssertions;
    };
}
