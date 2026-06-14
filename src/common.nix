# General-purpose helpers shared across the src/ modules and flake.nix.
{ pkgs }:
let
  lib = pkgs.lib;
  # Pick the first non-null element from a priority-ordered list.
  firstNonNull = builtins.foldl' (acc: x: if acc != null then acc else x) null;
in
{
  # Join non-empty strings with newlines.
  concatNonEmpty = strs: lib.concatStringsSep "\n" (lib.filter (s: s != "") strs);

  # Emit `_PATH="<pkg>/bin:$_PATH"` lines for prepending packages to PATH.
  mkPathLines = pkgs: lib.concatMapStringsSep "\n" (pkg: ''_PATH="${pkg}/bin:$_PATH"'') pkgs;

  # Pick the first non-null value for `field` from a priority-ordered list of attrsets (nulls skipped).
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
}
