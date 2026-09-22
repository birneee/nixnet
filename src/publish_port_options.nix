{ pkgs }:
let
  lib = pkgs.lib;
in
lib.types.listOf (
  lib.types.coercedTo lib.types.port (port: { inherit port; }) (
    lib.types.submodule (
      { config, ... }:
      {
        options = {
          port = lib.mkOption {
            type = lib.types.port;
            description = "Internal port to publish.";
          };
          hostPort = lib.mkOption {
            type = lib.types.port;
            default = config.port;
            defaultText = lib.literalExpression "port";
            description = "Host port to publish it as.";
          };
          protocol = lib.mkOption {
            type = lib.types.enum [ "tcp" "udp" ];
            default = "tcp";
            description = "Protocol to publish. UDP is tracked as flows with timeouts (NAT-like), fine for request/response.";
          };
          hostAddr = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Host address to bind to. Defaults to all addresses.";
          };
        };
      }
    )
  )
)
