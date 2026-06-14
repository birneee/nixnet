{ pkgs }:
let
  lib = pkgs.lib;
in
lib.types.submodule {
  options = {
    delayMs = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "One-way delay in milliseconds.";
    };
    lossPercent = lib.mkOption {
      type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
      default = null;
      description = "Packet loss percentage between 0 and 100 (e.g. 1 for 1%).";
    };
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
}
