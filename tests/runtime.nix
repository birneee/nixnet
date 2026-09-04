{ pkgs, ... }:
let
  lib = pkgs.lib;

  jail_pkg = pkgs.callPackage ../jail/pkgs/jail.nix { };

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  mkExperiment =
    networkConfig:
    import ../src/testbed_jail.nix {
      inherit pkgs jail_pkg;
      config = (evalConfig networkConfig).config;
    };

  # Builds a test script that runs the testbed and asserts its exit code.
  mkExitCodeTest =
    name: networkConfig: expected:
    let
      testbed = mkExperiment { imports = [ networkConfig ]; workDir = null; };
    in
    pkgs.writeShellApplication {
      name = "test-nixnet-${name}";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        _rc=0
        ${lib.getExe testbed} || _rc=$?
        [ "$_rc" -eq ${toString expected} ] || {
          echo "expected exit ${toString expected}, got $_rc"
          exit 1
        }
      '';
    };
in
{
  # Awaited script exits non-zero → testbed exits 1
  test-nixnet-awaited-script-fails = mkExitCodeTest "awaited-script-fails" {
    name = "testbed";
    nodes.n.scripts.fail = {
      exec = "exit 1";
      await = true;
    };
  } 1;

  # Foreground script exits non-zero → testbed exits 1
  test-nixnet-foreground-script-fails = mkExitCodeTest "foreground-script-fails" {
    name = "testbed";
    nodes.n.scripts.fail = {
      exec = "exit 1";
      foreground = true;
    };
  } 1;

  # Non-awaited background script exits non-zero → testbed exits 1
  # The sentinel gives fail script enough time to exit before.
  test-nixnet-background-script-fails = mkExitCodeTest "background-script-fails" {
    name = "testbed";
    nodes.n.scripts = {
      fail.exec = "exit 1";
      sentinel = { exec = "sleep 1"; await = true; };
    };
  } 1;

  # Awaited script exits 0 → testbed exits 0
  test-nixnet-awaited-script-succeeds = mkExitCodeTest "awaited-script-succeeds" {
    name = "testbed";
    nodes.n.scripts.ok = {
      exec = "exit 0";
      await = true;
    };
  } 0;
}
