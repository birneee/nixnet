{ pkgs, tb }:
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
      text = builtins.readFile ./write_run_json;
    }).outPath
    + "/bin/write_run_json";
  namespaces = tb.namespaces;
  veths = tb.veths;
  workDir = tb.workDir;
  workDirEnsureEmpty = tb.workDirEnsureEmpty;

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

  inherit (import ./common.nix { inherit pkgs; }) concatNonEmpty mkPathLines resolveFirst resolveNetem;

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

  nodeScripts = import ./node_script.nix { inherit pkgs tb; };

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
        pipewire = lib.optionalString (nsCfg != null && (nsCfg.sharePipeWire or false)) (
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
        ) (nsAutoHostBinds.${name} or [ ]);
      in
      lib.concatStringsSep "\n" (
        [ "_PATH=\"\" # clear path" ]
        ++ [ nsPathLines ]
        ++ lib.optional (dir != "") "mkdir -p '${dir}'"
        ++ [
          "jail add \\\n  --setenv PATH=$_PATH${
            lib.optionalString (dir != "") " \\\n  --bind '${dir}' /pwd \\\n  --chdir /pwd"
          }${wayland}${pipewire}${binds} \\\n  ${name}"
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


  runPhaseSections = lib.concatStringsSep "\n\n" (
    lib.filter (s: s != "") [
      (mkBashSection "pre-run hook" [ tb.preRun ])
      (mkBashSection "launch background scripts" nodeScripts.launchScripts)
      (mkBashSection "launch foreground scripts" nodeScripts.fgScripts)
      (lib.strings.trim ''
        # wait for background processes marked as await
        _FAILED=0
        for PID in "''${WAIT_PIDS[@]}"; do
          while kill -0 "$PID" 2>/dev/null; do
            sleep 0.1
          done
          _EXIT=0
          wait "$PID" 2>/dev/null || _EXIT=$?
          echo "testbed| PID $PID exited with $_EXIT"
          [ "$_EXIT" -eq 0 ] || _FAILED=1
          PIDS=("''${PIDS[@]/$PID}")
        done
        [ "$_FAILED" -eq 0 ] || exit 1
        stop_pids
      '')
      (mkBashSection "post-run hook" [ tb.postRun ])
    ]
  );

  scriptText =
    ''
      #!${pkgs.bash}/bin/bash
      set -o errexit
      set -o nounset
      set -o pipefail
    
      set -m  # enable job control: each background job gets its own process group
    
      PIDS=()
      WAIT_PIDS=()
      _FAILED=0
    
      stop_pids() {
        for PID in "''${PIDS[@]}"; do
          [ -n "$PID" ] || continue
          if [ -e "/proc/$PID" ]; then
            kill -INT -- -"$PID" 2>/dev/null || true
            echo "testbed| PID $PID killed"
            _deadline=$((SECONDS + 5))
            while [ -e "/proc/$PID" ] && (( SECONDS < _deadline )); do
              sleep 0.1
            done
            if [ -e "/proc/$PID" ]; then
              kill -KILL -- -"$PID" 2>/dev/null || true
            fi
            wait "$PID" || true
          else
            _EXIT=0
            wait "$PID" || _EXIT=$?
            echo "testbed| PID $PID exited with $_EXIT"
            [ "$_EXIT" -eq 0 ] || _FAILED=1
          fi
        done
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
  inherit (nodeScripts) nsScriptFiles tbScriptFiles;
}
