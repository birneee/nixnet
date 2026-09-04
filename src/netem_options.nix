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
    loss = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            model = lib.mkOption {
              type = lib.types.enum [
                "random"
                "state"
                "gemodel"
              ];
              default = "random";
              description = "Packet loss model: independent random loss, a 4-state Markov chain, or a Gilbert-Elliot model.";
            };
            percent = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''
                For model "random": the loss probability. For model "gemodel": the probability of
                starting in the bad (lossy) state.
              '';
            };
            p13 = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "state": P13, the packet loss probability (required).'';
            };
            p31 = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "state": P31, extends the model to a 2-state chain.'';
            };
            p32 = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "state": P32, extends the model to a 3-state chain (requires p31).'';
            };
            p23 = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "state": P23, extends the model to a 4-state chain (requires p32 and p14).'';
            };
            p14 = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "state": P14, extends the model to a 4-state chain (requires p32 and p23).'';
            };
            r = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "gemodel": R, the probability of exiting the bad state.'';
            };
            h = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "gemodel": 1-H, the loss probability in the bad state (requires r).'';
            };
            k = lib.mkOption {
              type = lib.types.nullOr (lib.types.addCheck lib.types.number (v: v >= 0 && v <= 100));
              default = null;
              description = ''For model "gemodel": 1-K, the loss probability in the good state (requires r and h).'';
            };
          };
        }
      );
      default = null;
      description = "Packet loss model. See tc-netem(8) for the semantics of each model's parameters.";
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
