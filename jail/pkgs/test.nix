{
  pkgs,
  jail ? pkgs.callPackage ./jail.nix { },
}:
pkgs.writeShellApplication {
  name = "jail-test";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.bash
    jail
  ];
  text = builtins.readFile ../test;
}
