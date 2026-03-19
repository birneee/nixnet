{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    let
      mkTestbedOptions =
        pkgs:
        let
          lib = pkgs.lib;
          nixosKernelOpts =
            (lib.evalModules {
              modules = [
                "${nixpkgs}/nixos/modules/config/sysctl.nix"
                { _module.check = false; }
              ];
            }).options.boot.kernel;
          nixosNetworkingOpts =
            let
              utils = import "${nixpkgs}/nixos/lib/utils.nix" {
                inherit lib pkgs;
                config = { };
              };
            in
            (lib.evalModules {
              modules = [
                "${nixpkgs}/nixos/modules/tasks/network-interfaces.nix"
                { _module.check = false; }
              ];
              specialArgs = { inherit utils pkgs; };
            }).options.networking;

          # Build a submodule options attrset from a spec tree mixed with NixOS options.
          # nixosRoot: dot-path prefix for the context (e.g. "networking"), used in description suffix.
          # ctx: NixOS options namespace (e.g. evaluated.options.networking).
          # spec: attrset tree where each value is one of:
          #   null            — inherit this option (description/type/default/example) from NixOS
          #   lib.mkOption {} — use this custom option as-is
          #   { "<name>" = subSpec; } — attrsOf keyed-by-name submodule; subSpec is the per-item spec
          #   other attrset   — recurse into NixOS submodule/namespace with this sub-spec
          inheritFromNixpkgs =
            nixosRoot: ctx: spec:
            let
              isOpt = x: x ? _type && x._type == "option";

              getSubOptions =
                nixosPath: type:
                if type ? getSubOptions then
                  type.getSubOptions [ ]
                else if type ? nestedTypes.elemType.getSubOptions then
                  type.nestedTypes.elemType.getSubOptions [ ]
                else
                  throw "inheritFromNixpkgs: cannot get sub-options of '${nixosPath}' (type: ${type.name or "unknown"})";

              build =
                pathSegs: context: specNode:
                lib.mapAttrs (
                  key: val:
                  let
                    nixosPath = lib.concatStringsSep "." (pathSegs ++ [ key ]);
                    nixosSuffix = " Same type as NixOS ${nixosPath}.";
                    child = context.${key};
                  in
                  if isOpt val then
                    val
                  else if val == null then
                    lib.mkOption (
                      {
                        description = (child.description or "") + nixosSuffix;
                        type = child.type or lib.types.unspecified;
                      }
                      // lib.optionalAttrs (child ? default) { inherit (child) default; }
                      // lib.optionalAttrs (child ? example) { inherit (child) example; }
                    )
                  else if val ? "<name>" then
                    lib.mkOption {
                      description = (child.description or "") + nixosSuffix;
                      default = { };
                      type = lib.types.attrsOf (
                        lib.types.submodule {
                          options = build (
                            pathSegs
                            ++ [
                              key
                              "<name>"
                            ]
                          ) (getSubOptions nixosPath child.type) val."<name>";
                        }
                      );
                    }
                  else if isOpt child then
                    lib.mkOption {
                      description = (child.description or "") + nixosSuffix;
                      default = { };
                      type = lib.types.submodule {
                        options = build (pathSegs ++ [ key ]) (getSubOptions nixosPath child.type) val;
                      };
                    }
                  else
                    lib.mkOption {
                      default = { };
                      type = lib.types.submodule {
                        options = build (pathSegs ++ [ key ]) child val;
                      };
                    }
                ) specNode;
            in
            build [ nixosRoot ] ctx spec;

          nixosSysctlOption = (inheritFromNixpkgs "boot.kernel" nixosKernelOpts { sysctl = null; }).sysctl;

          netem = lib.types.submodule {
            options = {
              delayMs = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "One-way delay in milliseconds.";
              };
              lossPercent = lib.mkOption {
                type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
                default = null;
                description = "Packet loss percentage between 0 and 100 (e.g. 1 for 1%).";
              };
              rateMbit = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "Rate limit in Mbit/s.";
              };
              limit = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "Queue size in packets. Takes precedence over autoLimit.";
              };
              autoLimit = lib.mkOption {
                type = lib.types.nullOr lib.types.bool;
                default = null;
                description = "Compute queue limit from bandwidth-delay product. Requires delayMs and rateMbit. Defaults to false if not set on link or interface level.";
              };
            };
          };
          iface = lib.types.submodule {
            options = {
              ns = lib.mkOption {
                type = lib.types.str;
                description = "Namespace or bridge for this endpoint.";
              };
              iface = lib.mkOption {
                type = lib.types.str;
                description = "Interface name within the namespace.";
              };
            };
          };
          # Per-interface options added to networking.interfaces.<name>.
          ifaceOptions = {
            netem = lib.mkOption {
              type = lib.types.nullOr netem;
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
        in
        {
          namespaces = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  packages = lib.mkOption {
                    type = lib.types.listOf lib.types.package;
                    default = [ ];
                    description = "Packages prepended to PATH for all scripts in this namespace.";
                  };
                  scripts = lib.mkOption {
                    default = [ ];
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          exec = lib.mkOption {
                            type = lib.types.str;
                            description = "Script to run in this namespace. May be multi-line.";
                          };
                          await = lib.mkOption {
                            type = lib.types.bool;
                            default = false;
                            description = "Wait for this script to finish before stopping the testbed.";
                          };
                          foreground = lib.mkOption {
                            type = lib.types.bool;
                            default = false;
                            description = "Run this script in the foreground without output redirection. Runs after all background scripts are started.";
                          };
                          packages = lib.mkOption {
                            type = lib.types.listOf lib.types.package;
                            default = [ ];
                            description = "Packages prepended to PATH for this script only.";
                          };
                          sandbox = lib.mkOption {
                            type = lib.types.nullOr lib.types.bool;
                            default = null;
                            description = "Sandbox this script with bubblewrap. Overrides namespace-level and top-level sandbox.";
                          };
                        };
                      }
                    );
                    description = "Scripts to run in this namespace, launched in parallel.";
                  };
                  stdout = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Enable script output from the console. Overrides top-level stdout.";
                  };
                  workDir = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Working directory for this namespace's scripts. Relative to the testbed workDir if not absolute.";
                  };
                  sandbox = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Sandbox all scripts in this namespace with bubblewrap. Overrides top-level sandbox.";
                  };
                  sysctl = nixosSysctlOption;
                  networking = lib.mkOption {
                    default = { };
                    description = "Network interface configuration. Compatible with NixOS networking.";
                    type = lib.types.submodule {
                      options = inheritFromNixpkgs "networking" nixosNetworkingOpts {
                        defaultGateway = null;
                        defaultGateway6 = null;
                        interfaces."<name>" = {
                          ipv4.addresses = null;
                          ipv4.routes = null;
                          ipv6.addresses = null;
                          ipv6.routes = null;
                          mtu = null;
                        }
                        // ifaceOptions;
                      };
                    };
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
                };
              }
            );
          };

          veths = lib.mkOption {
            default = [ ];
            type = lib.types.listOf (
              lib.types.submodule {
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
                  a = lib.mkOption {
                    type = iface;
                    description = "First endpoint of this veth pair.";
                  };
                  b = lib.mkOption {
                    type = iface;
                    description = "Second endpoint of this veth pair.";
                  };
                };
              }
            );
            description = "veth pairs to create between namespaces.";
          };

          bridges = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
            description = "Bridges to create. Each bridge gets its own network namespace of the same name.";
          };

          stdout = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable script output from the console for all namespaces. Can be overridden per namespace.";
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
          mtu = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Global default MTU for all veth interfaces. Can be overridden per interface via networking.interfaces.";
          };
          workDir = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default working directory for all namespace scripts.";
          };
          workDirEnsureEmpty = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Abort if workDir exists and is not empty, preventing existing results from being overwritten.";
          };
          packages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Packages prepended to PATH for all scripts in all namespaces.";
          };
          sandbox = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Sandbox all scripts with bubblewrap: read-only filesystem, write access limited to workDir. Can be overridden per namespace or per script.";
          };
          sysctl = nixosSysctlOption // {
            description = nixosSysctlOption.description + " Can be overridden per namespace.";
          };
          inheritPath = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Append the system PATH. Useful for accessing host tools not managed by Nix.";
          };
          preSetup = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Shell code to run before the setup phase (before namespaces and links are created). Runs as root.";
          };
          postSetup = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Shell code to run after the setup phase (after namespaces, links, and routes are configured). Runs as root.";
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
          name = lib.mkOption {
            type = lib.types.str;
            default = "network-testbed";
            description = "Name of the output binary.";
          };
        };

      # Pick the first non-null element from a priority-ordered list.
      firstNonNull = builtins.foldl' (acc: x: if acc != null then acc else x) null;
      # Pick the first non-null value for `field` from a priority-ordered list of attrsets (nulls in the list are skipped).
      resolveFirst =
        field: sources:
        firstNonNull (map (src: if src == null then null else src.${field} or null) sources);

      # Merge two netem configs field-by-field: interface fields override link fields.
      resolveNetem =
        linkNetem: ifaceNetem:
        let
          template = if ifaceNetem != null then ifaceNetem else linkNetem;
        in
        if template == null then
          null
        else
          builtins.mapAttrs (
            f: _:
            firstNonNull [
              (ifaceNetem.${f} or null)
              (linkNetem.${f} or null)
            ]
          ) template;

      buildTestbed =
        pkgs: tb:
        let
          lib = pkgs.lib;
          namespaces = tb.namespaces;
          veths = tb.veths;
          workDir = tb.workDir;
          workDirEnsureEmpty = tb.workDirEnsureEmpty;
          name = tb.name;

          # Look up the interface config for a veth endpoint from its namespace, or null if absent.
          getNsIface =
            node:
            if namespaces ? ${node.ns} && namespaces.${node.ns}.networking.interfaces ? ${node.iface} then
              namespaces.${node.ns}.networking.interfaces.${node.iface}
            else
              null;

          execNs = ns: lib.optionalString (ns != null) "ip netns exec ${ns} ";

          # Join non-empty strings with newlines.
          concatNonEmpty = strs: lib.concatStringsSep "\n" (lib.filter (s: s != "") strs);

          # Emit a commented bash section only when lines is non-empty.
          mkBashSection =
            title: lines:
            let
              content = concatNonEmpty lines;
            in
            lib.optionalString (content != "") "# ${title}\n${content}";

          # Generate two shell commands for both endpoints of a veth.
          mkVethPairCmds =
            f:
            map (
              veth:
              concatNonEmpty [
                (f veth.a)
                (f veth.b)
              ]
            ) veths;

          # True if (ns, ifaceName) is an endpoint of any veth.
          isVethEndpoint =
            ns: ifaceName:
            builtins.any (
              veth:
              (veth.a.ns == ns && veth.a.iface == ifaceName) || (veth.b.ns == ns && veth.b.iface == ifaceName)
            ) veths;

          # Compute the PATH for a script: user packages only (runtime deps are for the outer script).
          mkScriptPkgs = nsCfg: scriptCfg: tb.packages ++ nsCfg.packages ++ scriptCfg.packages;

          # Build _PATH assignment lines for a script's package list (indented for use inside a subshell).
          mkScriptPathLines =
            pkgs:
            [ (if tb.inheritPath then "  _PATH=\"$PATH\" # inherit PATH" else "  _PATH=\"\" # clear PATH") ]
            ++ map (p: "  _PATH=\"${lib.getBin p}/bin:$_PATH\"") pkgs;

          # Build the indented, escaped bash -c argument for a script entry.
          mkScriptArg =
            nsCfg: scriptCfg:
            let
              body = lib.strings.trim scriptCfg.exec;
              indented = lib.concatStringsSep "\n" (
                map (l: if l == "" then "" else "    " + l) (lib.splitString "\n" body)
              );
            in
            lib.escapeShellArg ("\n" + indented + "\n  ");

          # cd into the namespace workDir, creating it as the original user if needed.
          mkCdNs =
            nsCfg:
            lib.optionalString (nsCfg.workDir != null)
              "\${SUDO_UID:+setpriv --reuid=\"\$SUDO_UID\" --regid=\"\$SUDO_GID\" --clear-groups --} mkdir -p '${nsCfg.workDir}'\n  cd '${nsCfg.workDir}'";

          # Runtime dependencies of the generated testbed binary.
          # These are only for the outer script.
          runtimeDeps = [
            pkgs.bash
            pkgs.iproute2
            pkgs.coreutils
            pkgs.gnused
            pkgs.procps
            pkgs.util-linux
            pkgs.bubblewrap
          ];

          # Build the bwrap prefix for sandboxing a script (empty string when sandbox is disabled).
          # Mounts /nix read-only so scripts can access Nix-store binaries,
          # while only the current working directory is writable.
          mkBwrapPrefix =
            nsCfg: scriptCfg:
            let
              sandboxed = resolveFirst "sandbox" [
                scriptCfg
                nsCfg
                tb
              ];
            in
            lib.optionalString sandboxed ''"''${_BWRAP[@]}" --bind "$PWD" "$PWD" --'';

          # {} in workDir enables repeated-run mode: the script accepts N as $1
          # and loops N times, substituting {} with a zero-padded index each run.
          hasTemplate = workDir != null && lib.hasInfix "{}" workDir;

          # Create namespaces (including bridge namespaces)
          nsCreateCommands = map (
            name:
            lib.concatStringsSep "\n" [
              "ip netns add ${name}"
              "NETNS+=(${name})"
            ]
          ) (lib.attrNames namespaces ++ tb.bridges);

          # Bring loopback interfaces up
          nsLoUpCommands = lib.mapAttrsToList (name: _: "${execNs name}ip link set lo up") namespaces;

          nsPreSetupCommands = lib.mapAttrsToList (
            name: nsCfg:
            lib.optionalString (nsCfg.preSetup != "") ''
              ${execNs name}bash -c ${lib.escapeShellArg nsCfg.preSetup}
            ''
          ) namespaces;

          nsPostSetupCommands = lib.mapAttrsToList (
            name: nsCfg:
            lib.optionalString (nsCfg.postSetup != "") ''
              ${execNs name}bash -c ${lib.escapeShellArg nsCfg.postSetup}
            ''
          ) namespaces;

          # Testbed-level sysctl defaults (lowest priority, can be overridden via tb.sysctl or ns.sysctl)
          tbSysctlDefaults = {
            "net.ipv4.ping_group_range" = "0 2147483647";
            "net.ipv4.ip_unprivileged_port_start" = 0;
          };

          # Apply sysctl per namespace: tbSysctlDefaults < tb.sysctl < ns.sysctl
          nsSysctlCommands = lib.concatLists (
            lib.mapAttrsToList (
              name: nsCfg:
              let
                merged = tbSysctlDefaults // tb.sysctl // nsCfg.sysctl;
              in
              lib.mapAttrsToList (
                key: value:
                lib.optionalString (value != null) (
                  let
                    rendered =
                      if builtins.isBool value then
                        (if value then "1" else "0")
                      else if builtins.isString value then
                        "\"${value}\""
                      else
                        toString value;
                  in
                  "${execNs name}sysctl -w ${key}=${rendered} > /dev/null"
                )
              ) merged
            ) namespaces
          );

          # Build a tc netem command string from a resolved netem config and interface.
          mkNetemCmd =
            ns: netemCfg: mtu: dev:
            lib.optionalString (netemCfg != null) (
              let
                n = netemCfg;
                # BDP in bytes: rateMbit * 1_000_000 / 8 * delayMs / 1000
                # BDP in packets: BDP_bytes / mtu
                bdpPackets =
                  if n.delayMs != null && n.rateMbit != null && mtu != null then
                    n.rateMbit * 1000000 / 8 * n.delayMs / 1000 / mtu
                  else
                    null;
                effectiveLimit =
                  if n.limit != null then
                    n.limit
                  else if n.autoLimit == true then
                    if bdpPackets != null then
                      bdpPackets
                    else
                      throw "netem autoLimit requires delayMs, rateMbit, and mtu to all be set on interface '${dev}'"
                  else
                    null;
                params = lib.concatStringsSep " " (
                  lib.filter (s: s != "") [
                    (lib.optionalString (n.delayMs != null) "delay ${toString n.delayMs}ms")
                    (lib.optionalString (n.lossPercent != null) "loss ${toString n.lossPercent}%")
                    (lib.optionalString (n.rateMbit != null) "rate ${toString n.rateMbit}Mbit")
                    (lib.optionalString (effectiveLimit != null) "limit ${toString effectiveLimit}")
                  ]
                );
              in
              "${execNs ns}tc qdisc add dev ${dev} root netem ${params}"
            );

          # Create veth pairs
          vethCreateCommands = map (
            veth:
            "${execNs veth.a.ns}ip link add ${veth.a.iface} type veth peer name ${veth.b.iface} netns ${veth.b.ns}"
          ) veths;

          # All {nsName, ifaceName} pairs from networking.interfaces that are not a veth endpoint.
          dummyIfaces = lib.concatLists (
            lib.mapAttrsToList (
              nsName: nsCfg:
              lib.concatMap (
                ifaceName: lib.optional (!isVethEndpoint nsName ifaceName) { inherit nsName ifaceName; }
              ) (lib.attrNames nsCfg.networking.interfaces)
            ) namespaces
          );

          # Create dummy interfaces for networking.interfaces entries that have no veth endpoint
          dummyCreateCommands = map (
            { nsName, ifaceName }: "${execNs nsName}ip link add ${ifaceName} type dummy"
          ) dummyIfaces;

          # Collect {ns, iface, addr} for all addresses of a given IP version.
          collectAddrs =
            getAddrs:
            lib.concatLists (
              lib.mapAttrsToList (
                name: nsCfg:
                lib.concatLists (
                  lib.mapAttrsToList (
                    ifaceName: ifaceCfg:
                    map (a: {
                      ns = name;
                      iface = ifaceName;
                      addr = "${a.address}/${toString a.prefixLength}";
                    }) (getAddrs ifaceCfg)
                  ) nsCfg.networking.interfaces
                )
              ) namespaces
            );

          ipv4Addrs = collectAddrs (ifaceCfg: ifaceCfg.ipv4.addresses);
          ipv6Addrs = collectAddrs (ifaceCfg: ifaceCfg.ipv6.addresses);

          mkAddrCommands =
            ipCmd: addrs:
            map (
              {
                ns,
                iface,
                addr,
              }:
              "${execNs ns}${ipCmd} addr add ${addr} dev ${iface}"
            ) addrs;

          # Assign IPv4/IPv6 addresses
          ipv4AddrCommands = mkAddrCommands "ip" ipv4Addrs;
          ipv6AddrCommands = mkAddrCommands "ip -6" ipv6Addrs;

          # Bring veth interfaces up
          linkIfUpCommands = mkVethPairCmds (node: "${execNs node.ns}ip link set ${node.iface} up");

          # Bring dummy interfaces up
          dummyIfUpCommands = map (
            { nsName, ifaceName }: "${execNs nsName}ip link set ${ifaceName} up"
          ) dummyIfaces;

          # Attach veth interfaces to bridge
          linkBridgeCommands = mkVethPairCmds (
            node:
            lib.optionalString (builtins.elem node.ns tb.bridges) "${execNs node.ns}ip link set ${node.iface} master ${node.ns}"
          );

          # Configure MTU for all interfaces from networking.interfaces
          linkMtuCommands = lib.concatLists (
            lib.mapAttrsToList (
              nsName: nsCfg:
              lib.mapAttrsToList (
                ifaceName: ifaceCfg:
                let
                  mtu = resolveFirst "mtu" [
                    ifaceCfg
                    tb
                  ];
                in
                lib.optionalString (mtu != null) "${execNs nsName}ip link set ${ifaceName} mtu ${toString mtu}"
              ) nsCfg.networking.interfaces
            ) namespaces
          );

          # Configure ARP for veth endpoints
          linkArpCommands = map (
            veth:
            let
              arpA = resolveFirst "arp" [
                (getNsIface veth.a)
                veth
                tb
              ];
              arpB = resolveFirst "arp" [
                (getNsIface veth.b)
                veth
                tb
              ];
            in
            concatNonEmpty [
              (lib.optionalString (!arpA) "${execNs veth.a.ns}ip link set ${veth.a.iface} arp off")
              (lib.optionalString (!arpB) "${execNs veth.b.ns}ip link set ${veth.b.iface} arp off")
            ]
          ) veths;

          # Configure netem for veth pairs
          linkNetemCommands = map (
            veth:
            let
              ifaceA = getNsIface veth.a;
              ifaceB = getNsIface veth.b;
            in
            concatNonEmpty [
              (mkNetemCmd veth.a.ns (resolveNetem veth.netem (ifaceA.netem or null)) (resolveFirst "mtu" [
                ifaceA
                tb
              ]) veth.a.iface)
              (mkNetemCmd veth.b.ns (resolveNetem veth.netem (ifaceB.netem or null)) (resolveFirst "mtu" [
                ifaceB
                tb
              ]) veth.b.iface)
            ]
          ) veths;

          # Prefill ARP tables for veth pairs
          linkArpPrefillCommands = map (
            veth:
            let
              arpPrefillA = resolveFirst "arpPrefill" [
                (getNsIface veth.a)
                veth
                tb
              ];
              arpPrefillB = resolveFirst "arpPrefill" [
                (getNsIface veth.b)
                veth
                tb
              ];
              nsA = execNs veth.a.ns;
              nsB = execNs veth.b.ns;
              getIpv4s = node: (getNsIface node).ipv4.addresses or [ ];
              # Get MAC from peer once, then add a neigh entry for each of its IPv4 addresses.
              mkPrefill =
                nsLocal: localIface: nsPeer: peerIface: peerAddrs:
                lib.optionalString (peerAddrs != [ ]) (
                  "_MAC=$(${nsPeer}cat /sys/class/net/${peerIface}/address)\n"
                  + lib.concatStringsSep "\n" (
                    map (a: "${nsLocal}ip neigh add ${a.address} lladdr \"$_MAC\" dev ${localIface}") peerAddrs
                  )
                );
            in
            concatNonEmpty [
              (lib.optionalString arpPrefillA (mkPrefill nsA veth.a.iface nsB veth.b.iface (getIpv4s veth.b)))
              (lib.optionalString arpPrefillB (mkPrefill nsB veth.b.iface nsA veth.a.iface (getIpv4s veth.a)))
            ]
          ) veths;

          # Build per-namespace route commands for one IP version.
          # ipCmd: "ip" or "ip -6"; getGw: nsCfg -> gw|null; getRoutes: ifaceCfg -> list
          mkRouteCommands =
            ipCmd: getGw: getRoutes:
            lib.mapAttrsToList (
              name: nsCfg:
              let
                gw = getGw nsCfg;
              in
              concatNonEmpty (
                lib.optional (gw != null) (
                  "${execNs name}${ipCmd} route add default via ${gw.address}"
                  + lib.optionalString (gw.interface != null) " dev ${gw.interface}"
                  + lib.optionalString (gw.source != null) " src ${gw.source}"
                  + lib.optionalString (gw.metric != null) " metric ${toString gw.metric}"
                )
                ++ lib.concatLists (
                  lib.mapAttrsToList (
                    ifaceName: ifaceCfg:
                    map (
                      route:
                      "${execNs name}${ipCmd} route add ${route.address}/${toString route.prefixLength}"
                      + lib.optionalString (route.via or null != null) " via ${route.via}"
                      + " dev ${ifaceName}"
                    ) (getRoutes ifaceCfg)
                  ) nsCfg.networking.interfaces
                )
              )
            ) namespaces;

          # Declarative IPv4/IPv6 Routing
          ipv4RouteCommands = mkRouteCommands "ip" (nsCfg: nsCfg.networking.defaultGateway) (
            ifaceCfg: ifaceCfg.ipv4.routes
          );
          ipv6RouteCommands = mkRouteCommands "ip -6" (nsCfg: nsCfg.networking.defaultGateway6) (
            ifaceCfg: ifaceCfg.ipv6.routes
          );

          # Create bridge devices inside their namespaces.
          bridgeAddCommands = map (
            brName: "${execNs brName}ip link add ${brName} type bridge stp_state 0"
          ) tb.bridges;

          # Set bridges to up
          bridgeUpCommands = map (brName: "${execNs brName}ip link set ${brName} up") tb.bridges;

          setupPhaseSections = lib.concatStringsSep "\n\n" (
            lib.filter (s: s != "") [
              (mkBashSection "pre-setup hook" [ tb.preSetup ])
              (mkBashSection "create namespaces" nsCreateCommands)
              (mkBashSection "namespace pre-setup hooks" nsPreSetupCommands)
              (mkBashSection "sysctl settings" nsSysctlCommands)
              (mkBashSection "create bridges" bridgeAddCommands)
              (mkBashSection "create veth pairs" vethCreateCommands)
              (mkBashSection "create dummy interfaces" dummyCreateCommands)
              (mkBashSection "assign ipv4 addresses" ipv4AddrCommands)
              (mkBashSection "assign ipv6 addresses" ipv6AddrCommands)
              (mkBashSection "attach interfaces to bridges" linkBridgeCommands)
              (mkBashSection "set bridges up" bridgeUpCommands)
              (mkBashSection "set interfaces up" (nsLoUpCommands ++ linkIfUpCommands ++ dummyIfUpCommands))
              (mkBashSection "configure mtu" linkMtuCommands)
              (mkBashSection "configure arp" linkArpCommands)
              (mkBashSection "configure netem" linkNetemCommands)
              (mkBashSection "prefill arp" linkArpPrefillCommands)
              (mkBashSection "configure ipv4 routing" ipv4RouteCommands)
              (mkBashSection "configure ipv6 routing" ipv6RouteCommands)
              (mkBashSection "namespace post-setup hooks" nsPostSetupCommands)
              (mkBashSection "post-setup hook" [ tb.postSetup ])
            ]
          );

          # Launch scripts in parallel; mark awaited ones; skip foreground scripts
          launchScripts = lib.concatLists (
            lib.mapAttrsToList (
              name: nsCfg:
              lib.concatLists (
                map (
                  scriptCfg:
                  lib.optional (!scriptCfg.foreground) (
                    let
                      script = mkScriptArg nsCfg scriptCfg;
                      toOutput =
                        if
                          resolveFirst "stdout" [
                            nsCfg
                            tb
                          ]
                        then
                          "2>&1 | sed 's/^/${name}| /'"
                        else
                          "> /dev/null 2>&1";
                      cdNs = mkCdNs nsCfg;
                    in
                    concatNonEmpty (
                      [
                        "("
                        "  set +m"
                      ]
                      ++ lib.optional (cdNs != "") "  ${cdNs}"
                      ++ mkScriptPathLines (mkScriptPkgs nsCfg scriptCfg)
                      ++ [
                        "  stdbuf -oL ${execNs name}\${SUDO_UID:+setpriv --reuid=\"\$SUDO_UID\" --regid=\"\$SUDO_GID\" --clear-groups --} ${mkBwrapPrefix nsCfg scriptCfg} \"$_ENV\" PATH=\"$_PATH\" \"$_BASH\" -c ${script} ${toOutput}"
                        ") &"
                        "echo \"${name}| PID $! started\""
                        "PIDS+=($!)"
                      ]
                      ++ lib.optional scriptCfg.await "WAIT_PIDS+=($!)"
                    )
                  )
                ) nsCfg.scripts
              )
            ) namespaces
          );

          # Foreground scripts (run after background scripts are started)
          fgScripts = lib.concatLists (
            lib.mapAttrsToList (
              name: nsCfg:
              lib.concatLists (
                map (
                  scriptCfg:
                  lib.optional scriptCfg.foreground (
                    let
                      script = mkScriptArg nsCfg scriptCfg;
                      cdNs = mkCdNs nsCfg;
                    in
                    concatNonEmpty (
                      [
                        "echo \"${name}| start foreground script\""
                        "("
                      ]
                      ++ lib.optional (cdNs != "") "  ${cdNs}"
                      ++ mkScriptPathLines (mkScriptPkgs nsCfg scriptCfg)
                      ++ [
                        "  ${execNs name}\${SUDO_UID:+setpriv --reuid=\"\$SUDO_UID\" --regid=\"\$SUDO_GID\" --clear-groups --} ${mkBwrapPrefix nsCfg scriptCfg} \"$_ENV\" PATH=\"$_PATH\" \"$_BASH\" -c ${script}"
                        ")"
                        "echo \"${name}| end foreground script\""
                      ]
                    )
                  )
                ) nsCfg.scripts
              )
            ) namespaces
          );

          runPhaseSections = lib.concatStringsSep "\n\n" (
            lib.filter (s: s != "") [
              (mkBashSection "pre-run hook" [ tb.preRun ])
              (mkBashSection "launch background scripts" launchScripts)
              (mkBashSection "launch foreground scripts" fgScripts)
              (lib.strings.trim ''
                # wait for background processes marked as await
                for PID in "''${WAIT_PIDS[@]}"; do
                  wait "$PID" 2>/dev/null || true
                  echo "testbed| PID $PID ended"
                done
              '')
              (mkBashSection "post-run hook" [ tb.postRun ])
            ]
          );
        in
        pkgs.writeShellApplication {
          inherit name;
          excludeShellChecks = [ "SC2016" ]; # $PATH in bash -c single-quoted arg is intentional
          text = ''
            ${mkBashSection "setup PATH" (
              [ (if tb.inheritPath then "_PATH=\"$PATH\" # inherit PATH" else "_PATH=\"\" # clear PATH") ]
              ++ map (p: "_PATH=\"${lib.getBin p}/bin:$_PATH\"") runtimeDeps
              ++ [ "export PATH=\"$_PATH\"" ]
            )}

            if [ -z "''${_TESTBED_CLEAN_ENV+x}" ]; then
              exec env -i \
                _TESTBED_CLEAN_ENV=1 \
                SUDO_UID="''${SUDO_UID:-}" \
                SUDO_GID="''${SUDO_GID:-}" \
                DISPLAY="''${DISPLAY:-}" \
                XAUTHORITY="''${XAUTHORITY:-}" \
                WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-}" \
                DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-}" \
                "''${BASH_SOURCE[0]}" "$@"
            fi

            if [ "$EUID" -ne 0 ]; then echo "testbed| Error: Run as root"; exit 1; fi

            set -m  # enable job control: each background job gets its own process group

            PIDS=()
            WAIT_PIDS=()
            NETNS=()

            _BASH='${pkgs.bash}/bin/bash'
            _ENV='${pkgs.coreutils}/bin/env'
            _BWRAP=(bwrap --ro-bind /nix /nix --ro-bind /sys /sys --dev /dev --proc /proc --tmpfs /tmp --unshare-all --share-net --clearenv)

            cleanup() {
              echo "testbed| cleaning up..."
              for PID in "''${PIDS[@]}"; do
                [ -e "/proc/$PID" ] || continue
                if kill -INT -- -"$PID" 2>/dev/null; then
                  echo "testbed| PID $PID killed"
                fi
              done
              wait
              for NS in "''${NETNS[@]}"; do
                ip netns del "$NS" || true
                echo "testbed| netns del $NS"
              done
            }
            trap cleanup EXIT

            ${
              if hasTemplate then
                ''
                  # Accept a single run index (e.g. 3) or a range (e.g. 1-5).
                  IFS='-' read -r _START _END <<< "''${1:-0}"
                  if [ -n "$_END" ]; then
                    for _RUN_NUM in $(seq "$_START" "$_END"); do
                      "$0" "$_RUN_NUM" || true
                    done
                    exit 0
                  fi
                  _RUN=$(printf "%02d" "''${1:-0}")
                  _WORK_DIR='${workDir}'
                  _WORK_DIR="''${_WORK_DIR//\{\}/$_RUN}"
                ''
              else
                lib.optionalString (workDir != null) ''
                  _WORK_DIR='${workDir}'
                ''
            }
            ${lib.optionalString (workDir != null && workDirEnsureEmpty) ''
              if [ -d "$_WORK_DIR" ] && [ -n "$(ls -A "$_WORK_DIR" 2>/dev/null)" ]; then
                echo "testbed| Error: workDir is not empty: $_WORK_DIR"
                exit 1
              fi
            ''}
            ${lib.optionalString (workDir != null) ''
              ''${SUDO_UID:+setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --clear-groups --} mkdir -p "$_WORK_DIR"
              cd "$_WORK_DIR"
            ''}

            ${setupPhaseSections}

            echo "testbed| network topology set up"

            ${runPhaseSections}'';
        };
      buildMermaid =
        pkgs: tb:
        let
          lib = pkgs.lib;
          # Sanitize names for use as Mermaid node IDs (hyphens not allowed)
          nodeId = name: lib.replaceStrings [ "-" " " "." ] [ "_" "_" "_" ] name;

          mkIfaceLabel =
            veth: node:
            let
              nsIface =
                if tb.namespaces ? ${node.ns} && tb.namespaces.${node.ns}.networking.interfaces ? ${node.iface} then
                  tb.namespaces.${node.ns}.networking.interfaces.${node.iface}
                else
                  null;
              ipv4s = map (a: "${a.address}/${toString a.prefixLength}") (nsIface.ipv4.addresses or [ ]);
              netemCfg = resolveNetem veth.netem (nsIface.netem or null);
            in
            lib.concatStringsSep " " (
              lib.filter (s: s != "") (
                [ node.iface ]
                ++ ipv4s
                ++ lib.optionals (netemCfg != null) [
                  (lib.optionalString (netemCfg.delayMs != null) "${toString netemCfg.delayMs}ms")
                  (lib.optionalString (netemCfg.lossPercent != null) "${builtins.toJSON netemCfg.lossPercent}%loss")
                  (lib.optionalString (netemCfg.rateMbit != null) "${toString netemCfg.rateMbit}Mbit/s")
                ]
              )
            );

          nsDecls = lib.mapAttrsToList (name: _: "    ${nodeId name}[${name}]") tb.namespaces;

          ifaceDecls = lib.concatLists (
            map (
              veth:
              let
                idA = "${nodeId veth.a.iface}_${nodeId veth.a.ns}";
                idB = "${nodeId veth.b.iface}_${nodeId veth.b.ns}";
              in
              [
                "    ${idA}@{ shape: text, label: \"${mkIfaceLabel veth veth.a}\" }"
                "    ${idB}@{ shape: text, label: \"${mkIfaceLabel veth veth.b}\" }"
              ]
            ) tb.veths
          );

          edgeDecls = map (
            veth:
            let
              idA = "${nodeId veth.a.iface}_${nodeId veth.a.ns}";
              idB = "${nodeId veth.b.iface}_${nodeId veth.b.ns}";
            in
            "    ${nodeId veth.a.ns} --- ${idA} --- ${idB} --- ${nodeId veth.b.ns}"
          ) tb.veths;
        in
        lib.concatStringsSep "\n" ([ "graph LR" ] ++ nsDecls ++ ifaceDecls ++ edgeDecls) + "\n";

    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { pkgs, ... }:
        {
          legacyPackages =
            let
              lib = pkgs.lib;
              evalConfig =
                networkConfig:
                lib.evalModules {
                  modules = [
                    {
                      options = mkTestbedOptions pkgs;
                      config = networkConfig;
                    }
                  ];
                };
            in
            {
              options = (lib.evalModules { modules = [ { options = mkTestbedOptions pkgs; } ]; }).options;
              mkTestbed = networkConfig: buildTestbed pkgs (evalConfig networkConfig).config;
              mkMermaid = networkConfig: buildMermaid pkgs (evalConfig networkConfig).config;
            };
        };
    };
}
