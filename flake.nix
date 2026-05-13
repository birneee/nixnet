{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    jail = {
      url = "path:./jail";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    let
      mkTestbedOptions =
        pkgs:
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
          netem = import ./netem_options.nix pkgs;

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

        in
        {
          namespaces = lib.mkOption {
            default = { };
            description = "Network namespaces to create.";
            type = lib.types.attrsOf (
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
                  networking = import ./networking_options.nix { inherit pkgs nixpkgs; };
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
              }
            );
            description = "veth pairs to create between namespaces.";
          };

          bridges = lib.mkOption {
            default = [ ];
            type = lib.types.listOf lib.types.str;
            description = "Bridges to create. Each bridge gets its own network namespace of the same name.";
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
          namespacePackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = with pkgs; [
              bash
              coreutils
              gnused
              iproute2
              procps
              util-linux
            ];
            description = "Packages prepended to PATH for all namespaces. Lower priority than namespace-level packages. Defaults to a set of standard tools; extend with \`lib.mkOptionDefault [ yourPkg ]\`.";
          };
          testbedPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = with pkgs; [
              bash
              coreutils
              gnused
              iproute2
              procps
              util-linux
            ];
            description = "Packages prepended to PATH for testbed hooks (preSetup, postSetup, preRun, postRun) and testbed-level scripts. Defaults to a set of standard tools; extend with \`lib.mkOptionDefault [ yourPkg ]\`.";
          };
          sysctl = nixosSysctlOption // {
            description = nixosSysctlOption.description + " Can be overridden per namespace.";
          };
          shareWayland = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Bind the Wayland display socket and graphics devices into the sandbox, enabling GUI applications.";
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
                    description = "Script to run in the testbed context (no network namespace). May be multi-line.";
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
            );
            description = "Scripts to run in the testbed context (outside any network namespace). Background scripts are launched in parallel with namespace scripts; foreground scripts run sequentially after all background scripts are started.";
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
        pkgs: jail_pkg: tb:
        let
          lib = pkgs.lib;
          writeRunJson =
            (pkgs.writeShellApplication {
              name = "write_run_json";
              runtimeInputs = with pkgs; [
                coreutils
                gnugrep
                gawk
                findutils
                inetutils
              ];
              text = builtins.readFile ./src/write_run_json;
            }).outPath
            + "/bin/write_run_json";
          namespaces = tb.namespaces;
          veths = tb.veths;
          workDir = tb.workDir;
          workDirEnsureEmpty = tb.workDirEnsureEmpty;
          name = tb.name;

          # Find the veth that connects to a given namespace interface, or null if absent.
          getVeth =
            nsName: ifaceName:
            lib.findFirst (
              v: (v.a.ns == nsName && v.a.iface == ifaceName) || (v.b.ns == nsName && v.b.iface == ifaceName)
            ) null veths;

          # Look up the interface config for a veth endpoint from its namespace, or null if absent.
          getNsIface =
            node:
            if namespaces ? ${node.ns} && namespaces.${node.ns}.networking.interfaces ? ${node.iface} then
              namespaces.${node.ns}.networking.interfaces.${node.iface}
            else
              null;

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

          # Write a script entry to a store path, preserving Nix string context.
          mkScriptFile =
            nsName: idx: scriptCfg:
            pkgs.writeScript "${name}-script-${nsName}-${toString idx}" ''
              #!${pkgs.bash}/bin/bash
              ${scriptCfg.exec}
            '';

          # Pre-computed script files per namespace: { nsName -> [file0, file1, ...] }
          nsScriptFiles = lib.mapAttrs (
            nsName: nsCfg: lib.imap0 (idx: scriptCfg: mkScriptFile nsName idx scriptCfg) nsCfg.scripts
          ) namespaces;

          # Pre-computed script files for top-level testbed scripts: [file0, file1, ...]
          tbScriptFiles = lib.imap0 (idx: scriptCfg: mkScriptFile "testbed" idx scriptCfg) tb.scripts;

          # {run} in workDir enables repeated-run mode: the script accepts N as $1
          # and loops N times, substituting {run} with a zero-padded index each run.
          hasTemplate = workDir != null && lib.hasInfix "{run}" workDir;

          mkPathLines = pkgs: lib.concatMapStringsSep "\n" (pkg: ''_PATH="${pkg}/bin:$_PATH"'') pkgs;

          # Extract host paths embedded via nixnet.hostBind from a string's Nix context.
          extractHostBinds =
            str:
            lib.concatMap (
              storePath:
              lib.optional
                (lib.hasSuffix "-nixnet-hostbind" (baseNameOf storePath))
                (lib.trim (builtins.readFile storePath))
            ) (lib.attrNames (builtins.getContext str));

          # Extract host bind paths from a nixnet.linkFarm package.
          extractHostBindsFromPkg =
            pkg:
            if pkg._nixnetLinkFarm or false then
              lib.concatMap extractHostBinds (pkg._binds or [ ])
            else
              [ ];

          # Auto-collected host bind paths per namespace (from script exec strings + per-namespace packages + shared packages).
          nsAutoHostBinds = lib.mapAttrs (
            _nsName: nsCfg:
            lib.unique (
              lib.concatMap (scriptCfg: extractHostBinds scriptCfg.exec) nsCfg.scripts
              ++ lib.concatMap extractHostBindsFromPkg (nsCfg.packages ++ tb.namespacePackages)
            )
          ) namespaces;

          # Union of all namespace auto host bind paths.
          tbAutoHostBinds = lib.unique (lib.concatLists (lib.attrValues nsAutoHostBinds));

          # Create namespaces (including bridge namespaces)
          nsCreateCommands =
            map (
              name:
              let
                nsCfg = namespaces.${name} or null;
                dir = lib.optionalString (nsCfg != null && nsCfg.workDir != null) (
                  builtins.replaceStrings [ "{namespace}" ] [ name ] nsCfg.workDir
                );
                nsPkgs = (nsCfg.packages or [ ]) ++ tb.namespacePackages;
                nsPathLines = mkPathLines nsPkgs;
                wayland = lib.optionalString (nsCfg != null && (nsCfg.shareWayland or false)) " \\\n  --wayland";
                binds = lib.concatMapStrings (p: " \\\n  --bind '/host${p}' '/host${p}'") (nsAutoHostBinds.${name} or [ ]);
              in
              lib.concatStringsSep "\n" (
                [ "_PATH=\"\" # clear path" ]
                ++ [ nsPathLines ]
                ++ lib.optional (dir != "") "mkdir -p '${dir}'"
                ++ [
                  "jail add \\\n  --setenv PATH=$_PATH${
                    lib.optionalString (dir != "") " \\\n  --bind '${dir}' /pwd \\\n  --chdir /pwd"
                  }${wayland}${binds} \\\n  ${name}"
                ]
              )
            ) (lib.attrNames namespaces)
            ++ map (name: "jail add ${name}") tb.bridges;

          # Bring loopback interfaces up
          nsLoUpCommands = lib.mapAttrsToList (name: _: "ip netns exec ${name} ip link set lo up") namespaces;

          nsPreSetupCommands = lib.mapAttrsToList (
            name: nsCfg:
            lib.optionalString (nsCfg.preSetup != "") ''
              ip netns exec ${name} bash -c ${lib.escapeShellArg nsCfg.preSetup}
            ''
          ) namespaces;

          nsPostSetupCommands = lib.mapAttrsToList (
            name: nsCfg:
            lib.optionalString (nsCfg.postSetup != "") ''
              ip netns exec ${name} bash -c ${lib.escapeShellArg nsCfg.postSetup}
            ''
          ) namespaces;

          # Testbed-level sysctl defaults (lowest priority, can be overridden via tb.sysctl or ns.sysctl)
          tbSysctlDefaults = {
            "net.ipv4.ping_group_range" = "0 0";
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
                  "ip netns exec ${name} sysctl -w ${key}=${rendered} > /dev/null"
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
              "ip netns exec ${ns} tc qdisc add dev ${dev} root netem ${params}"
            );

          # Create veth pairs
          vethCreateCommands = map (
            veth:
            "ip netns exec ${veth.a.ns} ip link add ${veth.a.iface} type veth peer name ${veth.b.iface} netns ${veth.b.ns}"
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
            { nsName, ifaceName }: "ip netns exec ${nsName} ip link add ${ifaceName} type dummy"
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
              "ip netns exec ${ns} ${ipCmd} addr add ${addr} dev ${iface}"
            ) addrs;

          # Assign IPv4/IPv6 addresses
          ipv4AddrCommands = mkAddrCommands "ip" ipv4Addrs;
          ipv6AddrCommands = mkAddrCommands "ip -6" ipv6Addrs;

          # Bring veth interfaces up
          linkIfUpCommands = mkVethPairCmds (node: "ip netns exec ${node.ns} ip link set ${node.iface} up");

          # Bring dummy interfaces up
          dummyIfUpCommands = map (
            { nsName, ifaceName }: "ip netns exec ${nsName} ip link set ${ifaceName} up"
          ) dummyIfaces;

          # Attach veth interfaces to bridge
          linkBridgeCommands = mkVethPairCmds (
            node:
            lib.optionalString (builtins.elem node.ns tb.bridges) "ip netns exec ${node.ns} ip link set ${node.iface} master ${node.ns}"
          );

          # Configure MTU for all interfaces from networking.interfaces
          linkMtuCommands = lib.concatLists (
            lib.mapAttrsToList (
              nsName: nsCfg:
              lib.mapAttrsToList (
                ifaceName: ifaceCfg:
                let
                  veth = getVeth nsName ifaceName;
                  mtu = resolveFirst "mtu" [
                    ifaceCfg
                    veth
                    tb
                  ];
                in
                lib.optionalString (
                  mtu != null
                ) "ip netns exec ${nsName} ip link set ${ifaceName} mtu ${toString mtu}"
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
              (lib.optionalString (!arpA) "ip netns exec ${veth.a.ns} ip link set ${veth.a.iface} arp off")
              (lib.optionalString (!arpB) "ip netns exec ${veth.b.ns} ip link set ${veth.b.iface} arp off")
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
                veth
                tb
              ]) veth.a.iface)
              (mkNetemCmd veth.b.ns (resolveNetem veth.netem (ifaceB.netem or null)) (resolveFirst "mtu" [
                ifaceB
                veth
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
              nsA = "ip netns exec ${veth.a.ns} ";
              nsB = "ip netns exec ${veth.b.ns} ";
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
                  "ip netns exec ${name} ${ipCmd} route add default via ${gw.address}"
                  + lib.optionalString (gw.interface != null) " dev ${gw.interface}"
                  + lib.optionalString (gw.source != null) " src ${gw.source}"
                  + lib.optionalString (gw.metric != null) " metric ${toString gw.metric}"
                )
                ++ lib.concatLists (
                  lib.mapAttrsToList (
                    ifaceName: ifaceCfg:
                    map (
                      route:
                      "ip netns exec ${name} ${ipCmd} route add ${route.address}/${toString route.prefixLength}"
                      + lib.optionalString (route.via or null != null) " via ${route.via}"
                      + " dev ${ifaceName}"
                      + lib.concatStringsSep "" (lib.mapAttrsToList (k: v: " ${k} ${v}") (route.options or { }))
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
            brName: "ip netns exec ${brName} ip link add ${brName} type bridge stp_state 0"
          ) tb.bridges;

          # Set bridges to up
          bridgeUpCommands = map (brName: "ip netns exec ${brName} ip link set ${brName} up") tb.bridges;

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

          # All scripts as a flat list of { label, scriptPath, exec, scriptCfg }
          allScripts =
            lib.concatLists (
              lib.mapAttrsToList (
                name: nsCfg:
                lib.imap0 (idx: scriptCfg: {
                  label = name;
                  scriptPath = "\"$(dirname \"$0\")/../namespaces/${name}/scripts/${toString idx}\"";
                  exec = "jail enter ${name} ";
                  inherit scriptCfg;
                }) nsCfg.scripts
              ) namespaces
            )
            ++ lib.imap0 (idx: scriptCfg: {
              label = "testbed";
              scriptPath = "\"$(dirname \"$0\")/../scripts/${toString idx}\"";
              exec = "";
              inherit scriptCfg;
            }) tb.scripts;

          # Launch scripts in parallel; mark awaited ones; skip foreground scripts
          launchScripts = lib.concatMap (
            {
              label,
              scriptPath,
              exec,
              scriptCfg,
            }:
            lib.optional (!scriptCfg.foreground) (
              concatNonEmpty (
                [
                  "("
                  "  set +m"
                  "  set -o pipefail"
                  "  stdbuf -oL ${exec}${scriptPath} 2>&1 | sed 's/^/${label}| /'"
                  ") &"
                  "echo \"${label}| PID $! started\""
                  "PIDS+=($!)"
                ]
                ++ lib.optional scriptCfg.await "WAIT_PIDS+=($!)"
              )
            )
          ) allScripts;

          # Foreground scripts (run after background scripts are started)
          fgScripts = lib.concatMap (
            {
              label,
              scriptPath,
              exec,
              scriptCfg,
            }:
            lib.optional scriptCfg.foreground (concatNonEmpty [
              "echo \"${label}| start foreground script\""
              "("
              "  ${exec}${scriptPath}"
              ")"
              "echo \"${label}| end foreground script\""
            ])
          ) allScripts;

          runPhaseSections = lib.concatStringsSep "\n\n" (
            lib.filter (s: s != "") [
              (mkBashSection "pre-run hook" [ tb.preRun ])
              (mkBashSection "launch background scripts" launchScripts)
              (mkBashSection "launch foreground scripts" fgScripts)
              (lib.strings.trim ''
                # wait for background processes marked as await
                _FAILED=0
                for PID in "''${WAIT_PIDS[@]}"; do
                  _EXIT=0
                  wait "$PID" || _EXIT=$?
                  echo "testbed| PID $PID exited with $_EXIT"
                  [ "$_EXIT" -eq 0 ] || _FAILED=1
                  PIDS=("''${PIDS[@]/$PID}")
                done
                [ "$_FAILED" -eq 0 ] || exit 1
              '')
              (mkBashSection "post-run hook" [ tb.postRun ])
            ]
          );
          scriptText = ''
            #!${pkgs.bash}/bin/bash
            set -o errexit
            set -o nounset
            set -o pipefail

            set -m  # enable job control: each background job gets its own process group

            PIDS=()
            WAIT_PIDS=()

            cleanup() {
              _FAILED=$?
              echo "testbed| cleaning up..."
              for PID in "''${PIDS[@]}"; do
                [ -n "$PID" ] || continue
                if [ -e "/proc/$PID" ]; then
                  if kill -INT -- -"$PID" 2>/dev/null; then
                    echo "testbed| PID $PID killed"
                  fi
                  wait "$PID" || true
                else
                  _EXIT=0
                  wait "$PID" || _EXIT=$?
                  echo "testbed| PID $PID exited with $_EXIT"
                  [ "$_EXIT" -eq 0 ] || _FAILED=1
                fi
              done
              exit "$_FAILED"
            }
            trap cleanup EXIT

            ${lib.optionalString (workDir != null && workDirEnsureEmpty) ''
              if [ -n "$(ls -A . 2>/dev/null)" ]; then
                echo "testbed| Error: workDir is not empty: $(pwd)"
                exit 1
              fi
            ''}
            ${lib.optionalString (workDir != null) ''
              _STORE_PATH="$(dirname "$(dirname "$0")")"
              ${writeRunJson} "$_STORE_PATH"
            ''}

            ${setupPhaseSections}

            echo "testbed| network topology set up"

            ${runPhaseSections}'';
        in
        pkgs.stdenv.mkDerivation {
          pname = name;
          version = "0";
          dontUnpack = true;
          strictDeps = true;
          nativeBuildInputs = [ ];
          installPhase = ''
            mkdir -p $out/bin
          ''
          + lib.concatStrings (
            lib.mapAttrsToList (
              nsName: nsCfg:
              lib.concatStrings (
                lib.imap0 (
                  idx: _scriptCfg:
                  let
                    scriptFile = builtins.elemAt nsScriptFiles.${nsName} idx;
                  in
                  ''
                    mkdir -p $out/namespaces/${nsName}/scripts
                    install -m 0755 ${scriptFile} $out/namespaces/${nsName}/scripts/${toString idx}
                  ''
                ) nsCfg.scripts
              )
            ) namespaces
          )
          + lib.concatStrings (
            lib.imap0 (
              idx: _scriptCfg:
              let
                scriptFile = builtins.elemAt tbScriptFiles idx;
              in
              ''
                mkdir -p $out/scripts
                install -m 0755 ${scriptFile} $out/scripts/${toString idx}
              ''
            ) tb.scripts
          )
          + (
            let
              jailFlags =
                [ ''--setenv "PATH=$PATH"'' ]
                ++ lib.optional tb.shareWayland "--wayland"
                ++ map (p: "--bind '${p}' '/host${p}'") tbAutoHostBinds
                ++ lib.optionals (workDir != null) [
                  ''--bind "$_WORK_DIR" /pwd''
                  "--chdir /pwd"
                ];
            in
            ''
              install -m 0755 ${pkgs.writeScript name ''
                #!${pkgs.bash}/bin/bash
                set -euo pipefail

                _PATH="" # clear path
                ${mkPathLines (tb.testbedPackages ++ [ jail_pkg ])}
                export PATH="$_PATH"

                ${concatNonEmpty [
                  (if hasTemplate then
                    ''
                      IFS='-' read -r _START _END <<< "''${1:-}"
                      if [ -n "$_END" ]; then
                        for _RUN_NUM in $(seq "$_START" "$_END"); do
                          "$0" "$_RUN_NUM" || true
                        done
                        exit 0
                      fi
                      _RUN_NUM=''${_START:-0}
                      _WORK_DIR_TPL='${workDir}'
                      _WORK_DIR="''${_WORK_DIR_TPL//\{run\}/$(printf "%02d" "$_RUN_NUM")}"
                      while [ -z "''${1:-}" ] && [ -e "$_WORK_DIR" ]; do
                        _RUN_NUM=$((_RUN_NUM+1))
                        _WORK_DIR="''${_WORK_DIR_TPL//\{run\}/$(printf "%02d" "$_RUN_NUM")}"
                      done
                    ''
                  else
                    lib.optionalString (workDir != null) ''
                      _WORK_DIR='${workDir}'
                    '')
                  (lib.optionalString (workDir != null) ''
                    mkdir -p "$_WORK_DIR"
                    echo "testbed| workdir: $(realpath "$_WORK_DIR")"'')
                ]}

                exec jail exec \
                  ${lib.concatStringsSep " \\\n  " (jailFlags ++ [ "\"$(dirname \"$0\")/.${name}-wrapped\"" ])}
              ''} $out/bin/${name}
              install -m 0755 ${pkgs.writeScript "${name}-wrapped" scriptText} $out/bin/.${name}-wrapped
            ''
          );
          meta.mainProgram = name;
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
        { pkgs, lib, inputs', ... }:
        let
          jail_pkg = inputs'.jail.packages.default;
        in
        {
          packages.nixnet-option-docs =
            let
              optionsDoc =
                (pkgs.nixosOptionsDoc {
                  options = (lib.evalModules { modules = [ { options = mkTestbedOptions pkgs; } ]; }).options;
                  transformOptions =
                    opt:
                    opt
                    // {
                      visible = opt.visible && !(lib.any (lib.hasPrefix "_") (lib.splitString "." opt.name));
                    };
                }).optionsCommonMark;
            in
            pkgs.runCommand "nixnet-option-docs.md" { } ''
              echo "# NixNet Options" > $out
              echo >> $out
              cat ${optionsDoc} >> $out
            '';

          legacyPackages =
            let
              baseModule = {
                options = mkTestbedOptions pkgs;
              };
              evalConfig =
                networkConfig:
                lib.evalModules {
                  modules = [
                    baseModule
                    networkConfig
                  ];
                };
            in
            rec {
              options = (lib.evalModules { modules = [ baseModule ]; }).options;
              # Returns the path where p will be bind-mounted inside the jail (/host<p>).
              # The store file marker embeds p in the string's Nix context without changing
              # its value, allowing extractHostBinds to recover p at eval time.
              hostBind =
                p:
                let
                  marker = builtins.toFile "nixnet-hostbind" p;
                in
                "/host${p}${builtins.substring 0 0 marker}";
              # Like pkgs.linkFarm but entries with hostBind paths are automatically
              # detected and bind-mounted into namespaces at /host/...
              linkFarm =
                name: entries:
                (pkgs.linkFarm name entries).overrideAttrs (_: {
                  passthru = {
                    _nixnetLinkFarm = true;
                    _binds = map (e: e.path) entries;
                  };
                });
              mkTestbed = networkConfig: buildTestbed pkgs jail_pkg (evalConfig networkConfig).config;
              mkMermaid =
                networkConfig: pkgs.writeText "topology.mmd" (buildMermaid pkgs (evalConfig networkConfig).config);
              mkMermaidSvg =
                networkConfig:
                pkgs.runCommand "topology.svg"
                  {
                    buildInputs = [ pkgs.nodePackages.mermaid-cli ];
                    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.liberation_ttf ]; };
                    HOME = "/tmp";
                  }
                  ''
                    mmdc -i ${mkMermaid networkConfig} -o $out
                  '';
            };
        };
    };
}
