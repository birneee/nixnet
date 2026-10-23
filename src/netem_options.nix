{ pkgs }:
let
  lib = pkgs.lib;
  inherit (import ./common.nix { inherit pkgs; }) mkCascade mkRemovedOption;

  percentType = lib.types.numbers.between 0 100;
  mkPercentOption =
    description:
    lib.mkOption {
      type = percentType;
      inherit description;
    };
  # Unset optional parameters are omitted, leaving their defaults to tc.
  mkOptionalPercentOption =
    description:
    lib.mkOption {
      type = lib.types.nullOr percentType;
      default = null;
      inherit description;
    };
  formatPercent = v: "${builtins.toJSON v}%";

  # The kernel's u32 representation, tc's set_percent: rint(percent / 100 * UINT32_MAX), rounding half to even.
  uint32Max = 4294967295;
  toKernelProbability =
    percent:
    let
      scaled = percent / 100.0 * uint32Max;
      floor = builtins.floor scaled;
      fraction = scaled - floor;
    in
    if fraction > 0.5 || (fraction == 0.5 && lib.mod floor 2 == 1) then floor + 1 else floor;
  # Probabilities leaving one state must not overflow the kernel's u32 addition. Checked only when
  # both are set, tc's defaults never overflow.
  fitsKernelSum = a: b: a == null || b == null || toKernelProbability a + toKernelProbability b <= uint32Max;

  # Loss models of tc-netem(8), named like its keywords. `params` lists the
  # options in tc's positional order.
  # Semantics follow the kernel's loss_4state and loss_gilb_ell (net/sched/sch_netem.c).
  lossModels = {
    random = {
      description = ''
        Independent random loss, `loss random PERCENT [ CORRELATION ]`.
        The legacy form `loss PERCENT` is the same model.
      '';
      params = [ "percent" "correlation" ];
      module.options = {
        percent = mkPercentOption "PERCENT, the probability in percent that a packet is lost.";
        correlation = mkOptionalPercentOption ''
          CORRELATION in percent, how much the previous random value biases the next one.
          Only approximates burst losses, prefer `state` or `gemodel` for that.
        '';
      };
    };

    state = {
      description = ''
        4-state Markov chain, `loss state P13 [ P31 [ P32 [ P23 [ P14 ] ] ] ]`.
        The states are 1 packet received within a gap, 2 packet received within a burst,
        3 packet lost within a burst and 4 isolated packet loss within a gap.
        pXY is the per-packet probability in percent of moving from state X to state Y.
        As with tc, an optional parameter requires all before it, unset ones default to
        p31 = 100 - p13, p32 = 0, p23 = 100 and p14 = 0.
      '';
      params = [ "p13" "p31" "p32" "p23" "p14" ];
      module.options = {
        p13 = mkPercentOption "P13, from 1 (received in gap) to 3 (lost in burst): a loss burst starts.";
        p31 = mkOptionalPercentOption "P31, from 3 (lost in burst) to 1 (received in gap): the burst ends.";
        p32 = mkOptionalPercentOption "P32, from 3 (lost in burst) to 2 (received in burst).";
        p23 = mkOptionalPercentOption "P23, from 2 (received in burst) to 3 (lost in burst). State 2 has no other exit, so 0 makes it absorbing.";
        p14 = mkOptionalPercentOption "P14, from 1 (received in gap) to 4 (isolated loss). State 4 always returns to 1.";
      };
      assertions = m: [
        {
          assertion = fitsKernelSum m.p13 m.p14;
          message = "p13 + p14 must not exceed 100, both leave state 1 (summed after rounding, so e.g. 50 + 50 overflows too)";
        }
        {
          assertion = fitsKernelSum m.p31 m.p32;
          message = "p31 + p32 must not exceed 100, both leave state 3 (summed after rounding, so e.g. 50 + 50 overflows too)";
        }
      ];
    };

    gemodel = {
      description = ''
        Gilbert-Elliott burst loss model, `loss gemodel PERCENT [ R [ 1-H [ 1-K ] ] ]`.
        A good and a bad state, each with its own loss probability. As with tc, an optional
        parameter requires all before it, unset ones default to r = 100 - p, 1-H = 100 and
        1-K = 0. With only p set this reduces to random loss of p percent, setting r gives
        the Simple Gilbert model: every packet in the bad state is lost, none in the good state.
      '';
      params = [ "p" "r" "oneMinusH" "oneMinusK" ];
      module.options = {
        p = mkPercentOption ''
          PERCENT (shown as p by `tc qdisc show`), the per-packet probability of moving
          from the good to the bad state. Not, as tc-netem(8) puts it, the probability
          of starting in the bad state.
        '';
        r = mkOptionalPercentOption "R, the per-packet probability of moving from the bad to the good state.";
        oneMinusH = mkOptionalPercentOption "1-H, the loss probability in the bad state.";
        oneMinusK = mkOptionalPercentOption "1-K, the loss probability in the good state.";
      };
    };
  };

  lossModelOf =
    loss:
    let
      name = lib.head (lib.attrNames loss);
    in
    lossModels.${name} // { inherit name; values = loss.${name}; };

  # tc's parameters are positional, so each optional parameter requires its predecessor.
  positionalAssertions =
    model:
    lib.zipListsWith (previous: name: {
      assertion = model.values.${name} == null || model.values.${previous} != null;
      message = "`${name}` requires `${previous}`, tc's parameters are positional";
    }) model.params (lib.tail model.params);

  mkLossArgs =
    loss:
    let
      model = lossModelOf loss;
      setValues = lib.filter (v: v != null) (map (name: model.values.${name}) model.params);
    in
    "loss ${model.name} ${lib.concatMapStringsSep " " formatPercent setValues}";

  netemCascade = mkCascade {
    options = {
      delayMs = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "One-way delay in milliseconds.";
      };
      loss = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.attrTag (
            lib.mapAttrs (
              _: model:
              lib.mkOption {
                type = lib.types.submodule model.module;
                inherit (model) description;
              }
            ) lossModels
          )
        );
        default = null;
        example = lib.literalExpression "{ gemodel = { p = 1; r = 10; }; }";
        description = ''
          Packet loss model, exactly one of `random`, `state` or `gemodel`, mirroring
          `tc qdisc ... netem loss`. All parameters are percentages between 0 and 100.
          See tc-netem(8).
        '';
      };
      ecn = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Mark packets with Explicit Congestion Notification instead of dropping them (`ecn`). tc requires a loss model.";
      };
      lossPercent = mkRemovedOption;
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
    extraArgsDescription = ''
      Extra arguments appended verbatim to this interface's
      `tc qdisc add dev <iface> root netem ...` invocation, e.g.
      `[ "delay" "10ms" "2ms" "distribution" "normal" ]` or `[ "duplicate" "1%" ]`.
      Escape hatch for tc-netem(8) parameters not otherwise modeled, which must not
      repeat a modeled one. Interface-level only, not available on `veths.<name>.netem`.
    '';
  };
in
{
  inherit (netemCascade) type cascadeType;
  inherit mkLossArgs;

  # Assertions for a resolved netem config (see resolveNetem), `where` names the interface.
  assertions =
    where: n:
    lib.optionals (n != null && n.loss != null) (
      let
        model = lossModelOf n.loss;
      in
      map (a: a // { message = "nixnet: netem on ${where}: loss.${model.name}: ${a.message}"; }) (
        positionalAssertions model ++ (model.assertions or (_: [ ])) model.values
      )
    );

  # tc-netem(8) parameters for a resolved netem config.
  mkArgs =
    n: mtu: dev:
    let
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
      # absent when only veth-level netem is set
      extraArgs = if (n.extraArgs or null) != null then n.extraArgs else [ ];
    in
    lib.concatStringsSep " " (
      lib.filter (s: s != "") [
        (lib.optionalString (n.delayMs != null) "delay ${toString n.delayMs}ms")
        (lib.optionalString (n.loss != null) (mkLossArgs n.loss))
        (lib.optionalString (n.ecn == true) "ecn")
        (lib.optionalString (n.rateMbit != null) "rate ${toString n.rateMbit}Mbit")
        (lib.optionalString (effectiveLimit != null) "limit ${toString effectiveLimit}")
      ]
      ++ extraArgs
    );
}
