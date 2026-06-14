{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    let
      mkTestbedOptions = pkgs: import ./src/testbed_options.nix { inherit pkgs nixpkgs; };

      buildTestbed = import ./src/testbed_jail.nix;

    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        { pkgs, lib, ... }:
        let
          jail_pkg = pkgs.callPackage ./jail/pkgs/jail.nix { };
        in
        {
          packages.nixnet-option-docs = import ./src/option_docs.nix { inherit pkgs mkTestbedOptions; };

          legacyPackages =
            let
              baseModule = {
                options = mkTestbedOptions pkgs;
              };
              evalConfig =
                networkConfig:
                lib.evalModules {
                  modules = [
                    baseModule
                    networkConfig
                  ];
                };
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
              # detected and bind-mounted into namespaces at /host/... or /ro-host/..., respectively
              linkFarm =
                name: entries:
                (pkgs.linkFarm name entries).overrideAttrs (_: {
                  passthru = {
                    _nixnetLinkFarm = true;
                    _binds = map (e: e.path) entries;
                  };
                });
              mkTestbed = networkConfig: buildTestbed { inherit pkgs jail_pkg; tb = (evalConfig networkConfig).config; };
              mermaid = import ./src/mermaid.nix { inherit pkgs evalConfig; };
              inherit (mermaid) mkMermaid mkMermaidSvg;
            };
        };
    };
}
