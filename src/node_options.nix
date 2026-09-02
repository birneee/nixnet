{
  pkgs,
  nixpkgs,
  nixosSysctlOption,
}:
let
  lib = pkgs.lib;
  inherit (import ./common.nix { inherit pkgs; }) attrsOrLegacyList;
in
lib.types.submodule {
  options = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages prepended to PATH for all scripts in this node namespace. Takes precedence over nodePackages.";
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
                description = "Script to run in this node. May be multi-line.";
              };
              await = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Wait for this script to finish before stopping the testbed. Only applies to background scripts.";
              };
              foreground = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Run this script in the foreground without output redirection. Runs after all background scripts are started. Use for interactive shells or tools that require a terminal.";
              };
            };
          }
        )
      );
      description = "Scripts to run in this node. The attribute key is used as the script filename. Background scripts are launched in parallel; foreground scripts run sequentially after all background scripts are started.";
    };
    workDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "{node}";
      description = "Working directory for this node. Relative to the testbed workDir if not absolute. \`{node}\` is replaced with the node name.";
    };
    sysctl = nixosSysctlOption;
    networking = lib.mkOption {
      type = import ./networking_options.nix { inherit pkgs nixpkgs; };
      default = { };
      description = "Network interface configuration. Compatible with NixOS networking.";
    };
    preSetup = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run inside this node namespace after it is created. Runs after testbed preSetup.";
    };
    postSetup = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run inside this node namespace before testbed postSetup.";
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
  };
}
