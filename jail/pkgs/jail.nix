{ pkgs }:
let
  # todo move somewhere common
  inherit (import ../../src/common.nix { inherit pkgs; }) busyboxMini;
  deps = with pkgs; [
    bashNonInteractive
    coreutils
    util-linuxMinimal
    busyboxMini
  ];
  jail_init = pkgs.runCommand "jail_init" { nativeBuildInputs = [ pkgs.gcc pkgs.patchelf ]; } ''
    mkdir -p $out/bin
    gcc -O2 -o $out/bin/init ${../init.c}
    patchelf --shrink-rpath $out/bin/init
  '';
  jail = pkgs.writeShellApplication {
    name = "jail";
    runtimeInputs = deps ++ [ jail_init ];
    text = builtins.readFile ../jail;
  };
  jail_setup = pkgs.writeShellApplication {
    name = "jail_setup";
    runtimeInputs = deps;
    text = builtins.readFile ../jail_setup;
  };
in
pkgs.runCommand "jail" { } ''
  mkdir -p $out/bin
  cp ${jail}/bin/jail $out/bin/jail
  cp ${jail_setup}/bin/jail_setup $out/bin/jail_setup
  cp ${jail_init}/bin/init $out/bin/init
''
