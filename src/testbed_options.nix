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
          throw "nixnet: `veths` has changed from a list to an attribute set. Use `veths.eth0 = { a.node = \"client\"; b.node = \"server\"; }` instead of `veths = [{ a.ns = ...; }]`."
        else
          val;
      type = lib.types.either (lib.types.listOf lib.types.anything) (
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
        bashNonInteractive
        coreutils
        gnused
        iproute2
        util-linuxMinimal
      ];
      description = "Packages prepended to PATH for all nodes. Lower priority than node-level packages. Defaults to a set of standard tools; extend with \`lib.mkOptionDefault [ yourPkg ]\`.";
    };
    testbedPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        bashNonInteractive
        coreutils
        gnused
        iproute2
        util-linuxMinimal
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
          throw "nixnet: `scripts` has changed from a list to an attribute set. Use `scripts.name = { exec = ...; }` instead of `scripts = [{ exec = ...; }]`."
        else
          val;
      type = lib.types.either (lib.types.listOf lib.types.anything) (
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
      description = "Name of the output binary.";
    };
  };

  config.assertions = lib.concatLists (
    lib.mapAttrsToList (vethName: veth: [
      {
        assertion = veth.a.ns == null;
        message = "nixnet: `veths.${vethName}.a.ns` has been renamed to `node`";
      }
      {
        assertion = veth.b.ns == null;
        message = "nixnet: `veths.${vethName}.b.ns` has been renamed to `node`";
      }
    ]) config.veths
  );
}
