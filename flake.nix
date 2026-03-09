{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    let
      mkTestbedOptions =
        lib:
        let
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
              ns = lib.mkOption { type = lib.types.str; };
              ipv4 = lib.mkOption {
                type = lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])";
                description = "IPv4 address with prefix length, e.g. \"10.0.0.1/24\".";
              };
              mtu = lib.mkOption {
                type = lib.types.int;
                default = 1500;
                description = "MTU for this interface.";
              };
              netem = lib.mkOption {
                default = null;
                description = "netem traffic shaping parameters. Overrides link-level netem.";
                type = lib.types.nullOr netem;
              };
              arp = lib.mkOption {
                type = lib.types.nullOr lib.types.bool;
                default = null;
                description = "Enable ARP on this interface. Overrides link-level and top-level arp.";
              };
              arpPrefill = lib.mkOption {
                type = lib.types.nullOr lib.types.bool;
                default = null;
                description = "Prefill ARP table with the peer's MAC address. Overrides link-level and top-level arpPrefill.";
              };
            };
          };
        in
        {
          namespaces = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  ipv4Forward = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Enable IPv4 forwarding in this namespace.";
                  };
                  disableIpv6 = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Disable IPv6 in this namespace. Overrides top-level disableIpv6.";
                  };
                  ipUnprivilegedPortStart = lib.mkOption {
                    type = lib.types.int;
                    default = 0;
                    description = "Lowest port number that unprivileged users can bind to (net.ipv4.ip_unprivileged_port_start).";
                  };
                  defaultRoute = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Default route gateway for this namespace.";
                  };
                  routes = lib.mkOption {
                    default = [ ];
                    type = lib.types.listOf (
                      lib.types.submodule {
                        options = {
                          subnet = lib.mkOption {
                            type = lib.types.strMatching "(default|([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2]))";
                            description = "Destination subnet as IPv4 CIDR or \"default\".";
                          };
                          via = lib.mkOption { type = lib.types.str; };
                        };
                      }
                    );
                  };
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
                };
              }
            );
          };

          links = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  netem = lib.mkOption {
                    type = lib.types.nullOr netem;
                    default = null;
                    description = "netem traffic shaping parameters applied to both interfaces. Individual fields can be overridden per interface.";
                  };
                  arp = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Enable ARP for all interfaces on this link. Overrides top-level arp.";
                  };
                  arpPrefill = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Prefill ARP table for all interfaces on this link. Overrides top-level arpPrefill.";
                  };
                  a = lib.mkOption {
                    type = iface;
                    description = "First interface endpoint of this veth pair.";
                  };
                  b = lib.mkOption {
                    type = iface;
                    description = "Second interface endpoint of this veth pair.";
                  };
                };
              }
            );
          };

          disableIpv6 = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Disable IPv6 in all namespaces. Can be overridden per namespace.";
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
          name = lib.mkOption {
            type = lib.types.str;
            default = "network-testbed";
            description = "Name of the output binary.";
          };
        };

      ipv4RemovePrefix = cidr: builtins.head (builtins.split "/" cidr);

      # Pick the first non-null value for `field` across two or three attrsets (highest priority first).
      resolve2 = field: a: b: if a.${field} != null then a.${field} else b.${field};
      resolve3 = field: a: b: c: if a.${field} != null then a.${field} else if b.${field} != null then b.${field} else c.${field};

      # Merge two netem configs field-by-field: interface fields override link fields.
      resolveNetem =
        linkCfg: node:
        let
          l = linkCfg.netem;
          n = node.netem;
        in
        if l == null && n == null then
          null
        else
          builtins.mapAttrs (
            f: _: if n != null && n.${f} != null then n.${f} else if l != null then l.${f} else null
          ) (if n != null then n else l);

      buildTestbed =
        pkgs: tb:
        let
          lib = pkgs.lib;
          namespaces = tb.namespaces;
          links = tb.links;
          workDir = tb.workDir;
          workDirEnsureEmpty = tb.workDirEnsureEmpty;
          name = tb.name;

          resolveArp = linkCfg: node: resolve3 "arp" node linkCfg tb;
          resolveArpPrefill = linkCfg: node: resolve3 "arpPrefill" node linkCfg tb;

          # Join non-empty strings with newlines.
          concatNonEmpty = strs: lib.concatStringsSep "\n" (lib.filter (s: s != "") strs);

          # Generate two shell commands for both ends (a and b) of a link.
          mkLinkPairCmds = f: lib.mapAttrsToList (linkName: linkCfg: lib.concatStringsSep "\n" [
            (f linkName linkCfg.a)
            (f linkName linkCfg.b)
          ]) links;

          # Compute the PATH for a script: user packages only (runtime deps are for the outer script).
          mkScriptPkgs = nsCfg: scriptCfg: tb.packages ++ nsCfg.packages ++ scriptCfg.packages;

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
          mkCdNs = nsCfg: lib.optionalString (nsCfg.workDir != null) "\${SUDO_USER:+runuser -u \"$SUDO_USER\" --} mkdir -p '${nsCfg.workDir}'\n  cd '${nsCfg.workDir}'";

          # Runtime dependencies of the generated testbed binary.
          # Also included in every script's PATH via mkScriptArg.
          runtimeDeps = [
            pkgs.bash
            pkgs.iproute2
            pkgs.coreutils
            pkgs.procps
            pkgs.util-linux
            pkgs.bubblewrap
          ];

          # Build the bwrap prefix for sandboxing a script (empty string when sandbox is disabled).
          # Mounts /nix read-only so scripts can access Nix-store binaries,
          # while only the current working directory is writable.
          mkBwrapPrefix =
            nsCfg: scriptCfg:
            lib.optionalString (resolve3 "sandbox" scriptCfg nsCfg tb)
              ''"''${_BWRAP[@]}" --bind "$PWD" "$PWD" --'';

          # {} in workDir enables repeated-run mode: the script accepts N as $1
          # and loops N times, substituting {} with a zero-padded index each run.
          hasTemplate = workDir != null && lib.hasInfix "{}" workDir;

          # Create namespaces
          nsCreateCommands = lib.mapAttrsToList (
            name: nsCfg:
            lib.concatStringsSep "\n" [
              "ip netns add ${name}"
              "NETNS+=(${name})"
            ]
          ) namespaces;

          # Set ping group range
          nsPingGroupRangeCommands = lib.mapAttrsToList (
            name: _: "ip netns exec ${name} sysctl -w net.ipv4.ping_group_range=\"0 2147483647\" > /dev/null"
          ) namespaces;

          # Bring loopback interfaces up
          nsLoUpCommands = lib.mapAttrsToList (name: _: "ip netns exec ${name} ip link set lo up") namespaces;

          # Disable IPv6
          nsDisableIpv6Commands = lib.mapAttrsToList (
            name: nsCfg:
            lib.optionalString
              (resolve2 "disableIpv6" nsCfg tb)
              "ip netns exec ${name} sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null"
          ) namespaces;

          # Set ip_unprivileged_port_start
          nsUnprivilegedPortStartCommands = lib.mapAttrsToList (
            name: nsCfg:
            "ip netns exec ${name} sysctl -w net.ipv4.ip_unprivileged_port_start=${toString nsCfg.ipUnprivilegedPortStart} > /dev/null"
          ) namespaces;

          # Enable IPv4 forwarding
          nsForwardCommands = lib.mapAttrsToList (
            name: nsCfg:
            lib.optionalString nsCfg.ipv4Forward "ip netns exec ${name} sysctl -w net.ipv4.ip_forward=1 | sed 's/^/${name}| /'"
          ) namespaces;

          # Build a tc netem command string from a resolved netem config and interface.
          mkNetemCmd =
            ns: netemCfg: mtu: dev:
            lib.optionalString (netemCfg != null) (
              let
                n = netemCfg;
                # BDP in bytes: rateMbit * 1_000_000 / 8 * delayMs / 1000
                # BDP in packets: BDP_bytes / mtu
                bdpPackets =
                  if n.delayMs != null && n.rateMbit != null then
                    n.rateMbit * 1000000 / 8 * n.delayMs / 1000 / mtu
                  else
                    null;
                effectiveLimit =
                  if n.limit != null then
                    n.limit
                  else if n.autoLimit == true && bdpPackets != null then
                    bdpPackets
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
          linkCreateCommands = lib.mapAttrsToList (
            linkName: linkCfg:
            "ip netns exec ${linkCfg.a.ns} ip link add ${linkName} type veth peer name ${linkName} netns ${linkCfg.b.ns}"
          ) links;

          # Assign IP addresses
          linkAddrCommands = mkLinkPairCmds (linkName: iface: "ip netns exec ${iface.ns} ip addr add ${iface.ipv4} dev ${linkName}");

          # Bring link interfaces up
          linkIfUpCommands = mkLinkPairCmds (linkName: iface: "ip netns exec ${iface.ns} ip link set ${linkName} up");

          # Configure MTU
          linkMtuCommands = mkLinkPairCmds (linkName: iface: "ip netns exec ${iface.ns} ip link set ${linkName} mtu ${toString iface.mtu}");

          # Configure ARP
          linkArpCommands = lib.mapAttrsToList (
            linkName: linkCfg:
            let
              arpA = resolveArp linkCfg linkCfg.a;
              arpB = resolveArp linkCfg linkCfg.b;
            in
            concatNonEmpty [
              (lib.optionalString (!arpA) "ip netns exec ${linkCfg.a.ns} ip link set ${linkName} arp off")
              (lib.optionalString (!arpB) "ip netns exec ${linkCfg.b.ns} ip link set ${linkName} arp off")
            ]
          ) links;

          # Configure netem
          linkNetemCommands = lib.mapAttrsToList (
            linkName: linkCfg:
            concatNonEmpty [
              (mkNetemCmd linkCfg.a.ns (resolveNetem linkCfg linkCfg.a) linkCfg.a.mtu "${linkName}")
              (mkNetemCmd linkCfg.b.ns (resolveNetem linkCfg linkCfg.b) linkCfg.b.mtu "${linkName}")
            ]
          ) links;

          # Prefill ARP tables
          linkArpPrefillCommands = lib.mapAttrsToList (
            linkName: linkCfg:
            let
              arpPrefillA = resolveArpPrefill linkCfg linkCfg.a;
              arpPrefillB = resolveArpPrefill linkCfg linkCfg.b;
            in
            concatNonEmpty [
              (lib.optionalString arpPrefillA
                "_MAC=$(ip netns exec ${linkCfg.b.ns} cat /sys/class/net/${linkName}/address)\nip netns exec ${linkCfg.a.ns} ip neigh add ${ipv4RemovePrefix linkCfg.b.ipv4} lladdr \"$_MAC\" dev ${linkName}"
              )
              (lib.optionalString arpPrefillB
                "_MAC=$(ip netns exec ${linkCfg.a.ns} cat /sys/class/net/${linkName}/address)\nip netns exec ${linkCfg.b.ns} ip neigh add ${ipv4RemovePrefix linkCfg.a.ipv4} lladdr \"$_MAC\" dev ${linkName}"
              )
            ]
          ) links;

          # Declarative Routing
          routeCommands = lib.mapAttrsToList (
            name: nsCfg:
            concatNonEmpty (
              lib.optional (nsCfg.defaultRoute != null) "ip netns exec ${name} ip route add default via ${nsCfg.defaultRoute}"
              ++ map (route: "ip netns exec ${name} ip route add ${route.subnet} via ${route.via}") nsCfg.routes
            )
          ) namespaces;

          # Launch scripts in parallel; mark awaited ones; skip foreground scripts
          launchScripts = lib.concatLists (
            lib.mapAttrsToList (
              name: nsCfg:
              lib.concatLists (
                map (
                  scriptCfg:
                  lib.optional (!scriptCfg.foreground) (
                    let
                      scriptPath = lib.makeBinPath (mkScriptPkgs nsCfg scriptCfg);
                      script = mkScriptArg nsCfg scriptCfg;
                      toOutput = if resolve2 "stdout" nsCfg tb then "2>&1 | sed 's/^/${name}| /'" else "> /dev/null 2>&1";
                      cdNs = mkCdNs nsCfg;
                    in
                    concatNonEmpty [
                      "("
                      "  set +m"
                      (lib.optionalString (cdNs != "") "  ${cdNs}")
                      "  _PATH=\"${scriptPath}\""
                      "  stdbuf -oL ip netns exec ${name} \${SUDO_USER:+runuser -u \"$SUDO_USER\" --} ${mkBwrapPrefix nsCfg scriptCfg} \"$_ENV\" PATH=\"$_PATH\" \"$_BASH\" -c ${script} ${toOutput}"
                      ") &"
                      "echo \"${name}| PID $! started\""
                      "PIDS+=($!)"
                      (lib.optionalString scriptCfg.await "WAIT_PIDS+=($!)")
                    ]
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
                      scriptPath = lib.makeBinPath (mkScriptPkgs nsCfg scriptCfg);
                      script = mkScriptArg nsCfg scriptCfg;
                      cdNs = mkCdNs nsCfg;
                    in
                    concatNonEmpty [
                      "echo \"${name}| start foreground script\""
                      "("
                      (lib.optionalString (cdNs != "") "  ${cdNs}")
                      "  _PATH=\"${scriptPath}\""
                      "  ip netns exec ${name} \${SUDO_USER:+runuser -u \"$SUDO_USER\" --} ${mkBwrapPrefix nsCfg scriptCfg} \"$_ENV\" PATH=\"$_PATH\" \"$_BASH\" -c ${script}"
                      ")"
                      "echo \"${name}| end foreground script\""
                    ]
                  )
                ) nsCfg.scripts
              )
            ) namespaces
          );
        in
        pkgs.writeShellApplication {
          inherit name;
          excludeShellChecks = [ "SC2016" ]; # $PATH in bash -c single-quoted arg is intentional
          runtimeInputs = runtimeDeps;
          text = ''
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
              ''${SUDO_USER:+runuser -u "$SUDO_USER" --} mkdir -p "$_WORK_DIR"
              cd "$_WORK_DIR"
            ''}
            # create namespaces
            ${lib.concatStringsSep "\n" nsCreateCommands}

            # set ping group range
            ${lib.concatStringsSep "\n" nsPingGroupRangeCommands}

            # disable ipv6
            ${concatNonEmpty nsDisableIpv6Commands}

            # set unprivileged port start
            ${lib.concatStringsSep "\n" nsUnprivilegedPortStartCommands}

            # enable ip_forward
            ${concatNonEmpty nsForwardCommands}

            # create links
            ${lib.concatStringsSep "\n" linkCreateCommands}

            # assign addresses
            ${lib.concatStringsSep "\n" linkAddrCommands}

            # set interfaces up
            ${lib.concatStringsSep "\n" (nsLoUpCommands ++ linkIfUpCommands)}

            # configure mtu
            ${lib.concatStringsSep "\n" linkMtuCommands}

            # configure arp
            ${concatNonEmpty linkArpCommands}

            # configure netem
            ${concatNonEmpty linkNetemCommands}

            # prefill arp
            ${concatNonEmpty linkArpPrefillCommands}

            # configure routing
            ${concatNonEmpty routeCommands}

            echo "testbed| network topology & routing established"

            # launch background scripts
            ${lib.concatStringsSep "\n\n" launchScripts}

            # launch foreground scripts
            ${lib.concatStringsSep "\n\n" fgScripts}

            # wait for background processes marked as await
            for PID in "''${WAIT_PIDS[@]}"; do
              wait "$PID" 2>/dev/null || true
              echo "testbed| PID $PID ended"
            done'';
        };
      buildMermaid =
        lib: tb:
        let
          # Sanitize names for use as Mermaid node IDs (hyphens not allowed)
          nodeId = name: lib.replaceStrings [ "-" " " "." ] [ "_" "_" "_" ] name;

          mkIfaceLabel =
            linkName: linkCfg: node:
            let
              netemCfg = resolveNetem linkCfg node;
            in
            lib.concatStringsSep " " (
              lib.filter (s: s != "") (
                [
                  linkName
                  node.ipv4
                ]
                ++ lib.optionals (netemCfg != null) (
                  lib.filter (s: s != "") [
                    (lib.optionalString (netemCfg.delayMs != null) "${toString netemCfg.delayMs}ms")
                    (lib.optionalString (netemCfg.lossPercent != null) "${builtins.toJSON netemCfg.lossPercent}%loss")
                    (lib.optionalString (netemCfg.rateMbit != null) "${toString netemCfg.rateMbit}Mbit/s")
                  ]
                )
              )
            );

          nsDecls = lib.mapAttrsToList (name: _: "    ${nodeId name}[${name}]") tb.namespaces;

          ifaceDecls = lib.concatLists (
            lib.mapAttrsToList (
              linkName: linkCfg:
              let
                idA = "${nodeId linkName}_${nodeId linkCfg.a.ns}";
                idB = "${nodeId linkName}_${nodeId linkCfg.b.ns}";
              in
              [
                "    ${idA}@{ shape: text, label: \"${mkIfaceLabel linkName linkCfg linkCfg.a}\" }"
                "    ${idB}@{ shape: text, label: \"${mkIfaceLabel linkName linkCfg linkCfg.b}\" }"
              ]
            ) tb.links
          );

          edgeDecls = lib.mapAttrsToList (
            linkName: linkCfg:
            let
              idA = "${nodeId linkName}_${nodeId linkCfg.a.ns}";
              idB = "${nodeId linkName}_${nodeId linkCfg.b.ns}";
            in
            "    ${nodeId linkCfg.a.ns} --- ${idA} --- ${idB} --- ${nodeId linkCfg.b.ns}"
          ) tb.links;
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
          legacyPackages.mkTestbed =
            networkConfig:
            let
              lib = pkgs.lib;
              evaluated = lib.evalModules {
                modules = [
                  {
                    options = mkTestbedOptions lib;
                    config = networkConfig;
                  }
                ];
              };
            in
            buildTestbed pkgs evaluated.config;

          legacyPackages.mkMermaid =
            networkConfig:
            let
              lib = pkgs.lib;
              evaluated = lib.evalModules {
                modules = [
                  {
                    options = mkTestbedOptions lib;
                    config = networkConfig;
                  }
                ];
              };
            in
            buildMermaid lib evaluated.config;
        };
    };
}
