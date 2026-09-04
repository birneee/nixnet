{ pkgs }:
let
  lib = pkgs.lib;
  inherit (import ./common.nix { inherit pkgs; })
    mkCascade
    mkNullableBoolOption
    mkNullableIntOption
    resolveFirst
    ;
  # Option name -> ip-link(8) token and description, the single list both the
  # options and the commands are derived from. Names follow systemd.network's
  # [Link] section (Promiscuous, Multicast, AllMulticast) in NixOS casing.
  boolFlags = {
    promiscuous = {
      token = "promisc";
      description = "Set/unset IFF_PROMISC (promiscuous mode): receive all frames on the link, not just those addressed to this interface. Needed by anything reading frames via a raw socket that aren't addressed to its own MAC, e.g. a userspace L2 relay.";
    };
    multicast = {
      token = "multicast";
      description = "Set/unset IFF_MULTICAST (whether the interface is deemed multicast-capable).";
    };
    allMulticast = {
      token = "allmulticast";
      description = "Set/unset IFF_ALLMULTI: receive all multicast frames on the link, not just those it has joined a group for.";
    };
    trailers = {
      token = "trailers";
      description = "Set/unset trailer encapsulation. Only meaningful for a handful of legacy link types (e.g. some ARPHRD_ETHER drivers); a no-op for veths.";
    };
  };

  # The cascading (interface > veth > top-level) options: each is a single
  # scalar, so "most specific non-null wins" is unambiguous.
  cascadeOptions = lib.mapAttrs (_name: flag: mkNullableBoolOption flag.description) boolFlags // {
    transmitQueueLength = mkNullableIntOption "Transmit queue length (`ip link set dev <iface> txqueuelen <n>`).";
    alias = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Interface alias/label (`ip link set dev <iface> alias <name>`).";
    };
  };
in
mkCascade {
  options = cascadeOptions;
  extraArgsDescription = ''
    Extra arguments appended verbatim to this interface's
    `ip link set dev <iface> ...` invocation, e.g.
    `[ "group" "100" ]` or `[ "gso_max_size" "65536" ]`. Escape hatch for
    ip-link(8) settings not otherwise modeled. Interface-level only —
    not available on `veths.<name>.link` or the top-level `link` option.
  '';
}
// {
  # Bare `ip link set <iface> ...` commands (no ns wrapper) for one interface.
  # globalLink is the per-field fallback for dummy interfaces, a no-op for veth endpoints (already resolved by testbed_options.nix).
  mkCommands =
    ifaceLink: globalLink: iface:
    let
      get = field: resolveFirst field [ ifaceLink globalLink ];
      extraArgs = if ifaceLink.extraArgs != null then ifaceLink.extraArgs else [ ];
    in
    lib.mapAttrsToList (
      name: flag: "link set ${iface} ${flag.token} ${if get name then "on" else "off"}"
    ) (lib.filterAttrs (name: _: get name != null) boolFlags)
    ++ lib.optional (
      get "transmitQueueLength" != null
    ) "link set ${iface} txqueuelen ${toString (get "transmitQueueLength")}"
    ++ lib.optional (get "alias" != null) "link set ${iface} alias ${lib.escapeShellArg (get "alias")}"
    ++ lib.optional (extraArgs != [ ]) "link set ${iface} ${lib.concatStringsSep " " extraArgs}";
}
