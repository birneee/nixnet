{
  pkgs,
  nixpkgs,
  nixosSysctlOption,
}:
let
  lib = pkgs.lib;
in
lib.types.submodule {
  options = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Packages prepended to PATH for all scripts in this namespace. Takes precedence over namespacePackages.";
    };
    scripts = lib.mkOption {
      default = [ ];
      type = lib.types.listOf (
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
              description = "Script to run in this namespace. May be multi-line.";
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
      );
      description = "Scripts to run in this namespace. Background scripts are launched in parallel; foreground scripts run sequentially after all background scripts are started.";
    };
    workDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "{namespace}";
      description = "Working directory for this namespace. Relative to the testbed workDir if not absolute. \`{namespace}\` is replaced with the namespace name.";
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
      description = "Shell code to run inside this namespace after namespace is created. Runs after testbed preSetup. Runs as root.";
    };
    postSetup = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Shell code to run inside this namespace before testbed postSetup. Runs as root.";
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
