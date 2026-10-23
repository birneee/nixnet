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
    vm = lib.mkOption {
      type = lib.types.nullOr lib.types.deferredModule;
      default = null;
      example = lib.literalExpression ''
        { pkgs, ... }:
        {
          virtualisation.memorySize = 1024;
          environment.systemPackages = [ pkgs.iperf3 ];
          systemd.services.iperf = nixnet.vmService {
            exec = "iperf3 -c 10.0.0.2 > ./stdout";
            await = true;
          };
        }
      '';
      description = ''
        NixOS configuration making this node a VM (QEMU) with its own kernel, instead of a
        sandbox on the host's, with all of the node's interfaces. Set to `{ }` for a plain NixOS
        VM. Requires `/dev/kvm` and `/dev/vhost-net`. It starts with the experiment's scripts,
        its output prefixed like theirs, its console in `qemu.log` in the node's workDir, which
        is mounted at `/pwd`. QEMU settings go under `virtualisation`, e.g.
        `virtualisation.memorySize`, sysctl in `boot.kernel.sysctl`, a NIC's link settings,
        e.g. offloads, in `systemd.network.links.<interface>`, which names it.

        What runs in the VM are services, e.g. from `nixnet.vmService { exec; await ? false; }`,
        which runs `exec` like a node's script: once the network is online, in `/pwd`, with the
        VM's `environment.systemPackages`. The experiment awaits a VM with awaited services: it
        powers off once all of them finished, failing if any failed. A VM without awaited services
        is stopped with the experiment.

        Each interface of the node becomes a wire to the VM: tc redirects every frame
        between it and a tap device of the VM, both ways. Effects:

        - the VM's NIC is the end of the veth, with the interface's MAC address and mtu;
          netem still applies to the interface
        - the interface's addresses, routes and gateways are configured in the VM
        - the top-level `sysctl` doesn't reach the VM
        - options of a sandbox without an effect on a VM, e.g. `scripts`, `sysctl` or an
          interface's `arp`, `arpPrefill`, `link` or `ethtool`, are rejected
      '';
    };
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
    layer2Transparent = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Do not terminate a broadcast domain at this node: the veths on all of
        its interfaces are treated as one domain that continues through it,
        exactly as `bridges` does. Effects:

        - arpPrefill resolves the true remote endpoints reachable through this
          node, and embeds their real MAC addresses, instead of stopping at
          this node's own interface MACs
        - this node's own interfaces are not addressable members of that
          domain and get no arpPrefill entries
        - unlike `bridges`, no kernel bridge device is created and no
          interface is attached via `master`; nixnet sets up no forwarding at
          all

        Set it on a node that passes Ethernet frames between all of its
        interfaces itself, outside the kernel — e.g. a userspace raw-socket
        relay like PhantomLink. It only describes what the node already does,
        so do not set it on a node that forwards between just some of its
        interfaces, or that rewrites MAC addresses in transit.
      '';
    };
  };
}
