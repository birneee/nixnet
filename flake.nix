{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    let
      mkExperimentOptions = pkgs: import ./src/testbed_options.nix { inherit pkgs nixpkgs; };

      buildExperiment = import ./src/testbed_jail.nix;

    in
    flake-parts.lib.mkFlake { inherit inputs; } (
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "i686-linux"
      ];
    in
    {
      systems = supportedSystems;

      flake.supportedSystems = supportedSystems;

      perSystem =
        { pkgs, lib, ... }:
        let
          jail_pkg = pkgs.callPackage ./jail/pkgs/jail.nix { };
        in
        {
          packages.nixnet-option-docs = import ./src/option_docs.nix { inherit pkgs mkExperimentOptions; };
          packages.jail = jail_pkg;

          apps.test = {
            type = "app";
            program = lib.getExe (import ./src/test_runner.nix {
              inherit pkgs;
              testDirs = [ ./tests ./jail/tests ];
            });
          };

          # what vendor/update.sh needs on PATH
          devShells.default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              pandoc
              jq
              gnutar
              xz
            ];
          };

          legacyPackages =
            let
              common = import ./src/common.nix { inherit pkgs; };
              baseModule = mkExperimentOptions pkgs;
              compatModule = {
                imports = [
                  (common.mkRemovedOptionModule "namespaces" "has been renamed to `nodes`")
                  (common.mkRemovedOptionModule "namespacePackages" "has been renamed to `nodePackages`")
                ];
              };
              evalConfig =
                networkConfig:
                let
                  result = lib.evalModules {
                    modules = [
                      baseModule
                      compatModule
                      networkConfig
                    ];
                  };
                  failed = lib.filter (a: !a.assertion) result.config.assertions;
                in
                if failed != [ ] then throw (lib.concatMapStringsSep "\n" (a: a.message) failed) else result;
            in
            rec {
              options = (lib.evalModules { modules = [ baseModule ]; }).options;
              # Returns the path where p will be bind-mounted inside the jail (/host<p>).
              # The store file marker embeds p in the string's Nix context without changing
              # its value, allowing extractHostBinds to recover p at eval time.
              hostBind =
                p:
                let
                  marker = builtins.toFile "nixnet-hostbind" p;
                in
                "/host${p}${builtins.substring 0 0 marker}";

              # Returns the path where p will be readonly bind-mounted inside the jail (/ro-host<p>).
              # The store file marker embeds p in the string's Nix context without changing
              # its value, allowing extractHostBinds to recover p at eval time.
              roHostBind =
                p:
                let
                  marker = builtins.toFile "nixnet-ro-hostbind" p;
                in
                "/ro-host${p}${builtins.substring 0 0 marker}";

              # Like pkgs.linkFarm but entries with hostBind or roHostBind paths are automatically
              # detected and bind-mounted into nodes at /host/... or /ro-host/..., respectively
              linkFarm =
                name: entries:
                (pkgs.linkFarm name entries).overrideAttrs (_: {
                  passthru = {
                    _nixnetLinkFarm = true;
                    _binds = map (e: e.path) entries;
                  };
                });
              mkExperiment =
                networkConfig:
                buildExperiment {
                  inherit pkgs jail_pkg;
                  config = (evalConfig networkConfig).config;
                };

              mkTestbed = throw "nixnet: mkTestbed has been renamed to mkExperiment";

              mermaid = import ./src/mermaid.nix { inherit pkgs evalConfig; };
              inherit (mermaid) mkMermaidText mkMermaid mkMermaidSvg;
            };
        };
    });
}
