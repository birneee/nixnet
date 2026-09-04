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

  # Just the busybox applets actually needed anywhere in nixnet (sysctl, jail's
  # sed, write_run_json's grep/awk/find/xargs/sed), not all ~400 of them (which
  # would risk shadowing same-named tools elsewhere, e.g. busybox's own
  # `ping`/`mount`/`kill`/`init`).
  busyboxMini = pkgs.linkFarm "busybox-mini" (
    map (n: {
      name = "bin/${n}";
      path = "${pkgs.busybox}/bin/${n}";
    }) [ "sed" "sysctl" "grep" "awk" "find" "xargs" ]
  );

  # Attrs type that still type-checks the legacy list form, so `apply` can throw a
  # migration error instead of a type error. `either` hides sub-options from the
  # option docs, so restore them from the attrs type.
  attrsOrLegacyList =
    attrsType:
    lib.types.either (lib.types.listOf lib.types.anything) attrsType
    // {
      inherit (attrsType) getSubOptions;
    };

  # Nullable bool/unsigned-int mkOption, default null. Shared by link_options.nix and ethtool_options.nix.
  mkNullableBoolOption = description: lib.mkOption {
    type = lib.types.nullOr lib.types.bool;
    default = null;
    inherit description;
  };
  mkNullableIntOption = description: lib.mkOption {
    type = lib.types.nullOr lib.types.ints.unsigned;
    default = null;
    inherit description;
  };

  # Shape shared by the cascading (interface > veth > top-level) option modules,
  # link_options.nix and ethtool_options.nix: `fieldNames` for testbed_options.nix
  # to resolve, `cascadeType` for the veth-level and top-level options, and `type`
  # for the interface-level one, which additionally takes an `extraArgs` escape
  # hatch (no sensible override-vs-merge default across 3 levels).
  mkCascade =
    { options, extraArgsDescription }:
    {
      fieldNames = lib.attrNames options;
      cascadeType = lib.types.submodule { inherit options; };
      type = lib.types.submodule {
        options = options // {
          extraArgs = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            description = extraArgsDescription;
          };
        };
      };
    };

  # Pick the first non-null value for `field` from a priority-ordered list of attrsets (nulls skipped).
  resolveFirst =
    field: sources:
    firstNonNull (map (src: if src == null then null else src.${field} or null) sources);

  # Module that declares a removed option and adds an assertion when it is set.
  mkRemovedOptionModule =
    name: message:
    { config, ... }:
    {
      options.${name} = lib.mkOption {
        visible = false;
        default = null;
        type = lib.types.nullOr lib.types.anything;
      };
      config.assertions = [
        {
          assertion = config.${name} == null;
          message = "nixnet: `${name}` ${message}";
        }
      ];
    };

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
