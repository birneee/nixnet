{ pkgs, config }:
let
  lib = pkgs.lib;
  writeRunJson =
    (pkgs.writeShellApplication {
      name = "write_run_json";
      runtimeInputs = [
        pkgs.coreutils
        busyboxMini
      ];
      text = builtins.readFile ./write_run_json;
    }).outPath
    + "/bin/write_run_json";
  nodes = config.nodes;
  veths = lib.attrValues config.veths;
  workDir = config.workDir;
  workDirEnsureEmpty = config.workDirEnsureEmpty;

  # Find the veth that connects to a given node interface, or null if absent.
  getVeth =
    nodeName: ifaceName:
    lib.findFirst (
      v:
      (v.a.node == nodeName && v.a.iface == ifaceName) || (v.b.node == nodeName && v.b.iface == ifaceName)
    ) null veths;

  # Look up the interface config for a veth endpoint from its node, or null if absent.
  getNodeIface =
    endpoint:
    if nodes ? ${endpoint.node} && nodes.${endpoint.node}.networking.interfaces ? ${endpoint.iface} then
      nodes.${endpoint.node}.networking.interfaces.${endpoint.iface}
    else
      null;

  inherit (import ./common.nix { inherit pkgs; })
    busyboxMini
    concatNonEmpty
    mkPathLines
    resolveFirst
    resolveNetem
    ;

  # Emit a commented bash section only when lines is non-empty.
  mkBashSection =
    title: lines:
    let
      content = concatNonEmpty lines;
    in
    lib.optionalString (content != "") "# ${title}\n${content}";

  mkIpBatch =
    ipCmd: ns: lines:
    let
      indented = "\t" + lib.replaceStrings [ "\n" ] [ "\n\t" ] lines;
    in
    "${ipCmd} -n ${ns} -b - <<-'EOF'\n${indented}\nEOF";

  # Group {ns, bare} pairs by ns and emit one "ip -n ns -batch -" heredoc per ns.
  mkGroupedIpBatch =
    cmds:
    lib.mapAttrsToList (
      ns: entries:
      mkIpBatch "ip" ns (lib.concatMapStringsSep "\n" (e: e.bare) entries)
    ) (lib.groupBy (c: c.ns) cmds);

  # Produce a flat list of {ns, bare} by applying f to both endpoints of every veth.
  mkVethEndpointCmds = f: lib.concatMap (veth: f veth.a ++ f veth.b) veths;

  # True if (node, ifaceName) is an endpoint of any veth.
  isVethEndpoint =
    node: ifaceName:
    builtins.any (
      veth:
      (veth.a.node == node && veth.a.iface == ifaceName)
      || (veth.b.node == node && veth.b.iface == ifaceName)
    ) veths;

  nodeScripts = import ./node_script.nix { inherit pkgs config; };

  # Extract host paths embedded via nixnet.hostBind from a string's Nix context.
  # Returns list of AttrSet { path: string; readonly: bool;}
  extractHostBinds =
    str:
    lib.concatMap (
      storePath:
      if (lib.hasSuffix "-nixnet-hostbind" (baseNameOf storePath)) then
        [
          {
            path = lib.trim (builtins.readFile storePath);
            readonly = false;
          }
        ]
      else if (lib.hasSuffix "-nixnet-ro-hostbind" (baseNameOf storePath)) then
        [
          {
            path = lib.trim (builtins.readFile storePath);
            readonly = true;
          }
        ]
      else
        [ ]
    ) (lib.attrNames (builtins.getContext str));

  # Extract host bind paths from a nixnet.linkFarm package.
  # Returns list of AttrSet { path: string; readonly: bool;}
  extractHostBindsFromPkg =
    pkg:
    if pkg._nixnetLinkFarm or false then lib.concatMap extractHostBinds (pkg._binds or [ ]) else [ ];

  # Auto-collected host bind paths per node (from script exec strings + per-node packages + shared packages).
  nodeAutoHostBinds = lib.mapAttrs (
    _nodeName: nodeCfg:
    lib.unique (
      lib.concatMap (scriptCfg: extractHostBinds scriptCfg.exec) (lib.attrValues nodeCfg.scripts)
      ++ lib.concatMap extractHostBindsFromPkg (nodeCfg.packages ++ config.nodePackages)
    )
  ) nodes;

  # Union of all node auto host bind paths.
  tbAutoHostBinds = lib.unique (lib.concatLists (lib.attrValues nodeAutoHostBinds));

  # Create nodes (including bridge nodes)
  nodeCreateCommands =
    map (
      name:
      let
        nodeCfg = nodes.${name} or null;
        dir = lib.optionalString (nodeCfg != null && nodeCfg.workDir != null) (
          builtins.replaceStrings [ "{node}" ] [ name ] nodeCfg.workDir
        );
        nodePkgs = (nodeCfg.packages or [ ]) ++ config.nodePackages;
        nodePathLines = mkPathLines nodePkgs;
        wayland = lib.optionalString (
          nodeCfg != null && (nodeCfg.shareWayland or false)
        ) " \\\n  --wayland";
        pipewire = lib.optionalString (nodeCfg != null && (nodeCfg.sharePipeWire or false)) (
          " \\\n  --ro-bind \"$XDG_RUNTIME_DIR/\${PIPEWIRE_REMOTE:-pipewire-0}\" \"/run/user/0/pipewire-0\""
          + " \\\n  --ro-bind \"$XDG_RUNTIME_DIR/pulse/native\" \"/run/user/0/pulse/native\""
          + " \\\n  --setenv \"XDG_RUNTIME_DIR=/run/user/0\""
          + " \\\n  --setenv \"PIPEWIRE_REMOTE=pipewire-0\""
          + " \\\n  --setenv \"PULSE_SERVER=unix:/run/user/0/pulse/native\""
        );
        binds = lib.concatMapStrings (
          binding:
          if binding.readonly then
            " \\\n  --ro-bind '/ro-host${binding.path}' '/ro-host${binding.path}'"
          else
            " \\\n  --bind '/host${binding.path}' '/host${binding.path}'"
        ) (nodeAutoHostBinds.${name} or [ ]);
      in
      lib.concatStringsSep "\n" (
        [ "_PATH=\"\" # clear path" ]
        ++ [ nodePathLines ]
        ++ lib.optional (dir != "") "mkdir -p '${dir}'"
        ++ [
          "jail add \\\n  --setenv PATH=$_PATH${
            lib.optionalString (dir != "") " \\\n  --bind '${dir}' /pwd \\\n  --chdir /pwd"
          }${wayland}${pipewire}${binds} \\\n  ${name}"
        ]
      )
    ) (lib.attrNames nodes)
    ++ map (name: "jail add ${name}") config.bridges;

  # Bring loopback interfaces up
  nodeLoUpCommands = lib.mapAttrsToList (name: _: { ns = name; bare = "link set lo up"; }) nodes;

  nodePreSetupCommands = lib.mapAttrsToList (
    nodeName: nodeCfg:
    lib.optionalString (nodeCfg.preSetup != "") ''
      ip netns exec ${nodeName} bash -c ${lib.escapeShellArg nodeCfg.preSetup}
    ''
  ) nodes;

  nodePostSetupCommands = lib.mapAttrsToList (
    nodeName: nodeCfg:
    lib.optionalString (nodeCfg.postSetup != "") ''
      ip netns exec ${nodeName} bash -c ${lib.escapeShellArg nodeCfg.postSetup}
    ''
  ) nodes;

  # Testbed-level sysctl defaults (lowest priority, can be overridden via config.sysctl or nodeCfg.sysctl)
  tbSysctlDefaults = {
    "net.ipv4.ping_group_range" = "0 0";
    "net.ipv4.ip_unprivileged_port_start" = 0;
  };

  # Apply sysctl per node: tbSysctlDefaults < config.sysctl < nodeCfg.sysctl
  nodeSysctlCommands = lib.mapAttrsToList (
    nodeName: nodeCfg:
    let
      merged = tbSysctlDefaults // config.sysctl // nodeCfg.sysctl;
      pairs = lib.mapAttrsToList (
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
          "${key}=${rendered}"
        )
      ) merged;
      nonEmpty = lib.filter (s: s != "") pairs;
    in
    lib.optionalString (nonEmpty != [ ])
      "ip netns exec ${nodeName} sysctl -q -w \\\n  ${lib.concatStringsSep " \\\n  " nonEmpty}"
  ) nodes;

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
      "tc -n ${ns} qdisc add dev ${dev} root netem ${params}"
    );

  # Create veth pairs
  vethCreateCommands = map (
    veth:
    "ip -n ${veth.a.node} link add ${veth.a.iface} type veth peer name ${veth.b.iface} netns ${veth.b.node}"
  ) veths;

  # All {nodeName, ifaceName} pairs from networking.interfaces that are not a veth endpoint.
  dummyIfaces = lib.concatLists (
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      lib.concatMap (
        ifaceName: lib.optional (!isVethEndpoint nodeName ifaceName) { inherit nodeName ifaceName; }
      ) (lib.attrNames nodeCfg.networking.interfaces)
    ) nodes
  );

  # Create dummy interfaces for networking.interfaces entries that have no veth endpoint
  dummyCreateCommands = map (
    { nodeName, ifaceName }: { ns = nodeName; bare = "link add ${ifaceName} type dummy"; }
  ) dummyIfaces;

  # Collect {ns, iface, addr} for all addresses of a given IP version.
  collectAddrs =
    getAddrs:
    lib.concatLists (
      lib.mapAttrsToList (
        nodeName: nodeCfg:
        lib.concatLists (
          lib.mapAttrsToList (
            ifaceName: ifaceCfg:
            map (a: {
              node = nodeName;
              iface = ifaceName;
              addr = "${a.address}/${toString a.prefixLength}";
            }) (getAddrs ifaceCfg)
          ) nodeCfg.networking.interfaces
        )
      ) nodes
    );

  ipv4Addrs = collectAddrs (ifaceCfg: ifaceCfg.ipv4.addresses);
  ipv6Addrs = collectAddrs (ifaceCfg: ifaceCfg.ipv6.addresses);

  mkAddrCommands =
    ipCmd: addrs:
    lib.mapAttrsToList (
      node: nodeAddrs:
      mkIpBatch ipCmd node (lib.concatMapStringsSep "\n" (
        { iface, addr, ... }: "addr add ${addr} dev ${iface}"
      ) nodeAddrs)
    ) (lib.groupBy (a: a.node) addrs);

  # Assign IPv4/IPv6 addresses
  ipv4AddrCommands = mkAddrCommands "ip" ipv4Addrs;
  ipv6AddrCommands = mkAddrCommands "ip -6" ipv6Addrs;

  # Bring veth interfaces up
  linkIfUpCommands = mkVethEndpointCmds (e: [{ ns = e.node; bare = "link set ${e.iface} up"; }]);

  # Bring dummy interfaces up
  dummyIfUpCommands = map (
    { nodeName, ifaceName }: { ns = nodeName; bare = "link set ${ifaceName} up"; }
  ) dummyIfaces;

  # Attach veth interfaces to bridge
  linkBridgeCommands = mkVethEndpointCmds (
    e: lib.optional (builtins.elem e.node config.bridges) { ns = e.node; bare = "link set ${e.iface} master ${e.node}"; }
  );

  # Configure MTU for all interfaces from networking.interfaces
  linkMtuCommands = lib.concatLists (
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      lib.concatMap (
        ifaceName:
        let
          ifaceCfg = nodeCfg.networking.interfaces.${ifaceName};
          veth = getVeth nodeName ifaceName;
          mtu = resolveFirst "mtu" [ ifaceCfg veth config ];
        in
        lib.optional (mtu != null) { ns = nodeName; bare = "link set ${ifaceName} mtu ${toString mtu}"; }
      ) (lib.attrNames nodeCfg.networking.interfaces)
    ) nodes
  );

  # Configure ARP for veth endpoints
  linkArpCommands = lib.concatMap (
    veth:
    let
      arpA = resolveFirst "arp" [ (getNodeIface veth.a) veth config ];
      arpB = resolveFirst "arp" [ (getNodeIface veth.b) veth config ];
    in
    lib.optional (!arpA) { ns = veth.a.node; bare = "link set ${veth.a.iface} arp off"; }
    ++ lib.optional (!arpB) { ns = veth.b.node; bare = "link set ${veth.b.iface} arp off"; }
  ) veths;

  # Configure netem for veth pairs
  linkNetemCommands = map (
    veth:
    let
      ifaceA = getNodeIface veth.a;
      ifaceB = getNodeIface veth.b;
    in
    concatNonEmpty [
      (mkNetemCmd veth.a.node (resolveNetem veth.netem (ifaceA.netem or null)) (resolveFirst "mtu" [
        ifaceA
        veth
        config
      ]) veth.a.iface)
      (mkNetemCmd veth.b.node (resolveNetem veth.netem (ifaceB.netem or null)) (resolveFirst "mtu" [
        ifaceB
        veth
        config
      ]) veth.b.iface)
    ]
  ) veths;

  # Prefill ARP tables for veth pairs
  linkArpPrefillCommands = map (
    veth:
    let
      arpPrefillA = resolveFirst "arpPrefill" [
        (getNodeIface veth.a)
        veth
        config
      ];
      arpPrefillB = resolveFirst "arpPrefill" [
        (getNodeIface veth.b)
        veth
        config
      ];
      getIpv4s = node: (getNodeIface node).ipv4.addresses or [ ];
      # Get MAC from peer once, then add a neigh entry for each of its IPv4 addresses.
      mkPrefill =
        localNs: localIface: peerNs: peerIface: peerAddrs:
        lib.optionalString (peerAddrs != [ ]) (
          "_MAC=$(ip netns exec ${peerNs} cat /sys/class/net/${peerIface}/address)\n"
          + lib.concatStringsSep "\n" (
            map (a: "ip -n ${localNs} neigh add ${a.address} lladdr \"$_MAC\" dev ${localIface}") peerAddrs
          )
        );
    in
    concatNonEmpty [
      (lib.optionalString arpPrefillA (mkPrefill veth.a.node veth.a.iface veth.b.node veth.b.iface (getIpv4s veth.b)))
      (lib.optionalString arpPrefillB (mkPrefill veth.b.node veth.b.iface veth.a.node veth.a.iface (getIpv4s veth.a)))
    ]
  ) veths;

  # Build per-node route commands for one IP version.
  # ipCmd: "ip" or "ip -6"; getGw: nodeCfg -> gw|null; getRoutes: ifaceCfg -> list
  mkRouteCommands =
    ipCmd: getGw: getRoutes:
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      let
        gw = getGw nodeCfg;
        lines =
          lib.optional (gw != null) (
            "route add default via ${gw.address}"
            + lib.optionalString (gw.interface != null) " dev ${gw.interface}"
            + lib.optionalString (gw.source != null) " src ${gw.source}"
            + lib.optionalString (gw.metric != null) " metric ${toString gw.metric}"
          )
          ++ lib.concatLists (
            lib.mapAttrsToList (
              ifaceName: ifaceCfg:
              map (
                route:
                "route add ${route.address}/${toString route.prefixLength}"
                + lib.optionalString (route.via or null != null) " via ${route.via}"
                + " dev ${ifaceName}"
                + lib.concatStringsSep "" (lib.mapAttrsToList (k: v: " ${k} ${v}") (route.options or { }))
              ) (getRoutes ifaceCfg)
            ) nodeCfg.networking.interfaces
          );
      in
      lib.optionalString (lines != [ ])
        (mkIpBatch ipCmd nodeName (lib.concatStringsSep "\n" lines))
    ) nodes;

  # Declarative IPv4/IPv6 Routing
  ipv4RouteCommands = mkRouteCommands "ip" (nodeCfg: nodeCfg.networking.defaultGateway) (
    ifaceCfg: ifaceCfg.ipv4.routes
  );
  ipv6RouteCommands = mkRouteCommands "ip -6" (nodeCfg: nodeCfg.networking.defaultGateway6) (
    ifaceCfg: ifaceCfg.ipv6.routes
  );

  # Create bridge devices inside their own namespaces.
  bridgeAddCommands = map (
    brName: { ns = brName; bare = "link add ${brName} type bridge stp_state 0"; }
  ) config.bridges;

  # Set bridges to up
  bridgeUpCommands = map (brName: { ns = brName; bare = "link set ${brName} up"; }) config.bridges;

  setupPhaseSections = lib.concatStringsSep "\n\n" (
    lib.filter (s: s != "") [
      (mkBashSection "pre-setup hook" [ config.preSetup ])
      (mkBashSection "create nodes" nodeCreateCommands)
      (mkBashSection "node pre-setup hooks" nodePreSetupCommands)
      (mkBashSection "sysctl settings" nodeSysctlCommands)
      (mkBashSection "create bridges" (mkGroupedIpBatch bridgeAddCommands))
      (mkBashSection "create veth pairs" vethCreateCommands)
      (mkBashSection "create dummy interfaces" (mkGroupedIpBatch dummyCreateCommands))
      (mkBashSection "assign ipv4 addresses" ipv4AddrCommands)
      (mkBashSection "assign ipv6 addresses" ipv6AddrCommands)
      (mkBashSection "attach interfaces to bridges" (mkGroupedIpBatch linkBridgeCommands))
      (mkBashSection "set bridges up" (mkGroupedIpBatch bridgeUpCommands))
      (mkBashSection "set interfaces up" (mkGroupedIpBatch (nodeLoUpCommands ++ linkIfUpCommands ++ dummyIfUpCommands)))
      (mkBashSection "configure mtu" (mkGroupedIpBatch linkMtuCommands))
      (mkBashSection "configure arp" (mkGroupedIpBatch linkArpCommands))
      (mkBashSection "configure netem" linkNetemCommands)
      (mkBashSection "prefill arp" linkArpPrefillCommands)
      (mkBashSection "configure ipv4 routing" ipv4RouteCommands)
      (mkBashSection "configure ipv6 routing" ipv6RouteCommands)
      (mkBashSection "node post-setup hooks" nodePostSetupCommands)
      (mkBashSection "post-setup hook" [ config.postSetup ])
    ]
  );

  runPhaseSections = lib.concatStringsSep "\n\n" (
    lib.filter (s: s != "") [
      (mkBashSection "pre-run hook" [ config.preRun ])
      (mkBashSection "launch background scripts" nodeScripts.launchScripts)
      (mkBashSection "launch foreground scripts" nodeScripts.fgScripts)
      (lib.strings.trim ''
        # wait for background processes marked as await
        _FAILED=0
        while [ "''${#WAIT_PIDS[@]}" -gt 0 ]; do
          _EXIT=0
          _DONE=""
          wait -np _DONE "''${!PIDS[@]}" 2>/dev/null || _EXIT=$?  # watch all PIDs so background exits are collected
          [ -n "''${_DONE-}" ] || break
          echo "testbed| PID $_DONE exited with $_EXIT"
          [ "$_EXIT" -eq 0 ] || _FAILED=1
          unset "PIDS[$_DONE]"
          unset "WAIT_PIDS[$_DONE]"
        done
        [ "$_FAILED" -eq 0 ] || exit 1
        stop_pids
      '')
      (mkBashSection "post-run hook" [ config.postRun ])
    ]
  );

  scriptText = ''
    #!${pkgs.bashNonInteractive}/bin/bash
    set -o errexit
    set -o nounset
    set -o pipefail

    set -m  # enable job control: each background job gets its own process group

    declare -A PIDS=()
    declare -A WAIT_PIDS=()
    _FAILED=0

    stop_pids() {
      local -A _remaining=()
      for PID in "''${!PIDS[@]}"; do
        _remaining[$PID]=1
        kill -INT -- -"$PID" 2>/dev/null || true
        echo "testbed| PID $PID killed"
      done
      if [ "''${#_remaining[@]}" -gt 0 ]; then
        ( sleep 5
          for _p in "''${!_remaining[@]}"; do
            kill -KILL -- -"$_p" 2>/dev/null || true
          done
        ) &
        local _alarm=$!
        while [ "''${#_remaining[@]}" -gt 0 ]; do
          local _DONE=""
          wait -np _DONE "''${!_remaining[@]}" 2>/dev/null || true
          [ -n "''${_DONE-}" ] || break
          unset "_remaining[$_DONE]"
        done
        kill -- -"$_alarm" 2>/dev/null || true
        wait "$_alarm" 2>/dev/null || true
      fi
      PIDS=()
    }

    cleanup() {
      _FAILED=$?
      echo "testbed| cleaning up..."
      stop_pids
      exit "$_FAILED"
    }
    trap cleanup EXIT
    trap 'stop_pids; exit 130' INT TERM

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
{
  inherit scriptText tbAutoHostBinds;
  nodeScriptFiles = nodeScripts.nsScriptFiles;
  tbScriptFiles = nodeScripts.tbScriptFiles;
}
