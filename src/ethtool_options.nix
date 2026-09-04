{ pkgs }:
let
  lib = pkgs.lib;
  inherit (import ./common.nix { inherit pkgs; })
    mkCascade
    mkNullableBoolOption
    mkNullableIntOption
    resolveFirst
    ;

  # Vendored from ethtool's own man page, so descriptions can't drift into
  # paraphrase. Regenerate with vendor/update.sh after a nixpkgs bump; parsing it
  # here would mean import-from-derivation on every eval.
  manDescriptions = lib.importTOML ../vendor/ethtool_descriptions.toml;

  descriptionFor =
    descriptions: token:
    descriptions.${token}
      or (throw "ethtool_options.nix: no vendored description for '${token}' — rerun vendor/update.sh");

  # ethtool -K/--offload/--features fields -> short feature name.
  offloadFeatures =
    let
      d = descriptionFor manDescriptions.offload;
    in
    {
      receiveChecksumOffload = {
        token = "rx";
        description = d "rx";
      };
      transmitChecksumOffload = {
        token = "tx";
        description = d "tx";
      };
      scatterGather = {
        token = "sg";
        description = d "sg";
      };
      tcpSegmentationOffload = {
        token = "tso";
        description = d "tso";
      };
      udpFragmentationOffload = {
        token = "ufo";
        description = d "ufo";
      };
      genericSegmentationOffload = {
        token = "gso";
        description = d "gso";
      };
      genericReceiveOffload = {
        token = "gro";
        description = d "gro";
      };
      largeReceiveOffload = {
        token = "lro";
        description = d "lro";
      };
      receiveVLANCTAGHardwareAcceleration = {
        token = "rxvlan";
        description = d "rxvlan";
      };
      transmitVLANCTAGHardwareAcceleration = {
        token = "txvlan";
        description = d "txvlan";
      };
      nTupleFilter = {
        token = "ntuple";
        description = d "ntuple";
      };
      receiveHashingOffload = {
        token = "rxhash";
        description = d "rxhash";
      };
    };

  # ethtool -G/--set-ring (see ethtool(8)) field -> nix option name.
  ringFields =
    let
      d = descriptionFor manDescriptions.ring;
    in
    {
      rxBufferSize = {
        token = "rx";
        description = d "rx";
      };
      rxMiniBufferSize = {
        token = "rx-mini";
        description = d "rx-mini";
      };
      rxJumboBufferSize = {
        token = "rx-jumbo";
        description = d "rx-jumbo";
      };
      txBufferSize = {
        token = "tx";
        description = d "tx";
      };
    };

  # ethtool -C/--coalesce fields; no per-flag prose in ethtool.8.in's -C section, so descriptions here are original.
  coalesceBoolFields = {
    useAdaptiveRxCoalesce = {
      token = "adaptive-rx";
      description = "Whether the NIC should dynamically tune its RX interrupt coalescing based on traffic patterns (`ethtool -C <iface> adaptive-rx on|off`).";
    };
    useAdaptiveTxCoalesce = {
      token = "adaptive-tx";
      description = "Whether the NIC should dynamically tune its TX interrupt coalescing based on traffic patterns (`ethtool -C <iface> adaptive-tx on|off`).";
    };
  };
  coalesceIntFields = {
    rxCoalesceUsec = {
      token = "rx-usecs";
      description = "How long to wait, in microseconds, after an RX packet before triggering an interrupt (`ethtool -C <iface> rx-usecs <n>`). Trades latency for fewer interrupts.";
    };
    rxMaxCoalescedFrames = {
      token = "rx-frames";
      description = "Number of RX frames to wait for before triggering an interrupt (`ethtool -C <iface> rx-frames <n>`). Trades latency for fewer interrupts.";
    };
    txCoalesceUsec = {
      token = "tx-usecs";
      description = "How long to wait, in microseconds, after a TX packet before triggering an interrupt (`ethtool -C <iface> tx-usecs <n>`). Trades latency for fewer interrupts.";
    };
    txMaxCoalescedFrames = {
      token = "tx-frames";
      description = "Number of TX frames to wait for before triggering an interrupt (`ethtool -C <iface> tx-frames <n>`). Trades latency for fewer interrupts.";
    };
  };

  # ethtool -A/--pause (see ethtool(8)) fields -> nix option name.
  pauseFields =
    let
      d = descriptionFor manDescriptions.pause;
    in
    {
      autoNegotiationFlowControl = {
        token = "autoneg";
        description = d "autoneg";
      };
      rxFlowControl = {
        token = "rx";
        description = d "rx";
      };
      txFlowControl = {
        token = "tx";
        description = d "tx";
      };
    };

  onOff = v: if v then "on" else "off";

  # Turn a { name = { token, description }; ... } group into { name = mkOption; ... }.
  mkFieldOptions = mk: group: lib.mapAttrs (_name: field: mk field.description) group;

  # Cascading (interface > veth > top-level) options, grouped by ethtool invocation (-K/-G/-C/-A). Each is a scalar, so override-wins is unambiguous.
  cascadeOptions =
    (mkFieldOptions mkNullableBoolOption offloadFeatures)
    // (mkFieldOptions mkNullableIntOption ringFields)
    // (mkFieldOptions mkNullableBoolOption coalesceBoolFields)
    // (mkFieldOptions mkNullableIntOption coalesceIntFields)
    // (mkFieldOptions mkNullableBoolOption pauseFields);
in
mkCascade {
  options = cascadeOptions;
  extraArgsDescription = ''
    Extra arguments run as a plain `ethtool <iface> ...` invocation
    (ethtool's default "change settings" mode, e.g.
    `[ "speed" "1000" "duplex" "full" "autoneg" "off" ]`), for
    ethtool(8) settings not otherwise modeled. Interface-level only —
    not available on `veths.<name>.ethtool` or the top-level `ethtool`
    option.
  '';
}
// {
  # Bare `ethtool ...` commands (no ns wrapper) for one interface; globalEthtool is the per-field fallback, exactly like link_options.nix's mkCommands.
  mkCommands =
    ifaceEthtool: globalEthtool: iface:
    let
      get = field: resolveFirst field [ ifaceEthtool globalEthtool ];
      # "<token> <value>" args for one field group, skipping fields left unset.
      argsFor =
        render: group:
        lib.concatLists (
          lib.mapAttrsToList (
            name: field: lib.optional (get name != null) "${field.token} ${render (get name)}"
          ) group
        );
      offloadArgs = argsFor onOff offloadFeatures;
      ringArgs = argsFor toString ringFields;
      coalesceArgs = argsFor onOff coalesceBoolFields ++ argsFor toString coalesceIntFields;
      pauseArgs = argsFor onOff pauseFields;
      extraArgs = if ifaceEthtool.extraArgs != null then ifaceEthtool.extraArgs else [ ];
    in
    # ethtool reports applied changes on stdout, errors on stderr: drop stdout, so
    # only a real failure is printed (and aborts, via mkGroupedNsExec's `set -e`)
    map (cmd: "${cmd} > /dev/null") (
      # one -K per feature: batched, ethtool only fails if it could change *nothing*,
      # so a single refused feature among several would pass silently
      map (arg: "ethtool -K ${iface} ${arg}") offloadArgs
      ++ lib.optional (ringArgs != [ ]) "ethtool -G ${iface} ${lib.concatStringsSep " " ringArgs}"
      ++ lib.optional (coalesceArgs != [ ]) "ethtool -C ${iface} ${lib.concatStringsSep " " coalesceArgs}"
      ++ lib.optional (pauseArgs != [ ]) "ethtool -A ${iface} ${lib.concatStringsSep " " pauseArgs}"
      ++ lib.optional (extraArgs != [ ]) "ethtool ${iface} ${lib.concatStringsSep " " extraArgs}"
    );
}
