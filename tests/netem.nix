{ pkgs }:
let
  lib = pkgs.lib;
  netemModule = import ../src/netem_options.nix { inherit pkgs; };
  inherit (import ../src/common.nix { inherit pkgs; }) resolveNetem;
  inherit (import ./lib.nix { inherit pkgs; }) evalConfig failedAssertions;

  # A veth v0 between nodes a and b, with link-level and a-side interface-level netem.
  vethConfig =
    { link ? null, ifaceA ? null }:
    {
      nodes.a.networking.interfaces.v0.netem = ifaceA;
      nodes.b = { };
      veths.v0 = {
        netem = link;
        a.node = "a";
        b.node = "b";
      };
    };

  resolvedA =
    netem:
    let
      config = (evalConfig (vethConfig netem)).config;
    in
    resolveNetem config.veths.v0.netem config.nodes.a.networking.interfaces.v0.netem;

  argsOf = netem: netemModule.mkArgs (resolvedA netem) null "v0";
  failedAssertionsOf = netem: failedAssertions (vethConfig netem);
  isRejected = netem: !(builtins.tryEval (builtins.deepSeq (resolvedA netem) true)).success;
in
lib.runTests {
  testRandom = {
    expr = argsOf { link.loss.random.percent = 1; };
    expected = "loss random 1%";
  };
  testRandomCorrelation = {
    expr = argsOf { link.loss.random = { percent = 0.3; correlation = 25; }; };
    expected = "loss random 0.3% 25%";
  };
  # unset parameters are omitted, tc fills in its defaults
  testStateOnlySetParameters = {
    expr = argsOf { link.loss.state = { p13 = 5; p31 = 50; p32 = 30; }; };
    expected = "loss state 5% 50% 30%";
  };
  testStateAllParameters = {
    expr = argsOf { link.loss.state = { p13 = 5; p31 = 50; p32 = 30; p23 = 90; p14 = 1; }; };
    expected = "loss state 5% 50% 30% 90% 1%";
  };
  testGemodelOnlySetParameters = {
    expr = argsOf { link.loss.gemodel.p = 1; };
    expected = "loss gemodel 1%";
  };
  testEcn = {
    expr = argsOf { link = { delayMs = 10; loss.random.percent = 1; ecn = true; rateMbit = 100; }; };
    expected = "delay 10ms loss random 1% ecn rate 100Mbit";
  };

  # interface loss replaces the link loss as a whole, other fields cascade individually
  testIfaceLossReplacesLinkLoss = {
    expr = argsOf {
      link = { delayMs = 10; loss.random.percent = 1; };
      ifaceA.loss.gemodel.p = 2;
    };
    expected = "delay 10ms loss gemodel 2%";
  };
  testIfaceEcnWithLinkLoss = {
    expr = argsOf { link.loss.random.percent = 1; ifaceA.ecn = true; };
    expected = "loss random 1% ecn";
  };

  testExtraArgsAppended = {
    expr = argsOf { link.delayMs = 10; ifaceA.extraArgs = [ "duplicate" "1%" ]; };
    expected = "delay 10ms duplicate 1%";
  };
  testExtraArgsRejectedAtVethLevel = {
    expr = isRejected { link.extraArgs = [ "duplicate" "1%" ]; };
    expected = true;
  };

  # sums of exactly 100 are valid as long as the rounded u32 values do not overflow
  testValidConfigPassesAssertions = {
    expr = failedAssertionsOf { link.loss.state = { p13 = 5; p31 = 40; p32 = 60; p23 = 100; p14 = 95; }; };
    expected = [ ];
  };
  testStateLeavingState1Overflows = {
    expr = failedAssertionsOf { link.loss.state = { p13 = 60; p31 = 40; p32 = 0; p23 = 100; p14 = 50; }; };
    expected = [
      "nixnet: netem on a:v0: loss.state: p13 + p14 must not exceed 100, both leave state 1 (summed after rounding, so e.g. 50 + 50 overflows too)"
      "nixnet: netem on b:v0: loss.state: p13 + p14 must not exceed 100, both leave state 1 (summed after rounding, so e.g. 50 + 50 overflows too)"
    ];
  };
  # both halves of UINT32_MAX round up, wrapping the kernel's sum to 0
  testStateRoundingOverflows = {
    expr = failedAssertionsOf { ifaceA.loss.state = { p13 = 50; p31 = 50; p32 = 0; p23 = 100; p14 = 50; }; };
    expected = [
      "nixnet: netem on a:v0: loss.state: p13 + p14 must not exceed 100, both leave state 1 (summed after rounding, so e.g. 50 + 50 overflows too)"
    ];
  };
  testStateLeavingState3Overflows = {
    expr = failedAssertionsOf { ifaceA.loss.state = { p13 = 5; p31 = 95; p32 = 10; }; };
    expected = [
      "nixnet: netem on a:v0: loss.state: p31 + p32 must not exceed 100, both leave state 3 (summed after rounding, so e.g. 50 + 50 overflows too)"
    ];
  };
  # a gap would shift p32 into p31's position
  testStateGapRejected = {
    expr = failedAssertionsOf { ifaceA.loss.state = { p13 = 5; p32 = 30; }; };
    expected = [ "nixnet: netem on a:v0: loss.state: `p32` requires `p31`, tc's parameters are positional" ];
  };
  testGemodelGapRejected = {
    expr = failedAssertionsOf { ifaceA.loss.gemodel = { p = 1; oneMinusH = 70; }; };
    expected = [ "nixnet: netem on a:v0: loss.gemodel: `oneMinusH` requires `r`, tc's parameters are positional" ];
  };

  testRejectsTwoModels = {
    expr = isRejected { link.loss = { random.percent = 1; gemodel.p = 1; }; };
    expected = true;
  };
  testRejectsEmptyLoss = {
    expr = isRejected { link.loss = { }; };
    expected = true;
  };
  testRejectsForeignParameter = {
    expr = isRejected { link.loss.random = { percent = 1; p13 = 5; }; };
    expected = true;
  };
  # tc's argument is 1-H, a bare h would be ambiguous
  testRejectsAmbiguousH = {
    expr = isRejected { link.loss.gemodel = { p = 1; h = 70; }; };
    expected = true;
  };
  testRejectsMissingRequiredParameter = {
    expr = isRejected { link.loss.state.p31 = 5; };
    expected = true;
  };
  testRejectsPercentAbove100 = {
    expr = isRejected { link.loss.random.percent = 101; };
    expected = true;
  };
  testRejectsNegativePercent = {
    expr = isRejected { link.loss.gemodel.p = -1; };
    expected = true;
  };
}
