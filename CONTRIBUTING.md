# Contributing

Contributions are welcome — feel free to open issues or pull requests.

## Guidelines

- keep code elegant and readable
- give variables and files descriptive names
- find good abstractions, avoid duplication
- use files as logical units, single purpose and short
- inline short nix expressions
- define nix let bindings as close to their usage as possible
- nest nix attribute prefixes instead of repeating them
- keep comments and error messages short, terse fragments instead of full sentences
- add tests and assertions for new behavior
- document all features in nixnet-option-docs
- keep git diffs minimal
- take inspiration from nixpkgs
  - NixOS options
  - NixOS module system
  - testers.runNixOSTest
  - NixOS systemd networkd

## Testing

- run the test suite with `nix run .#test`
- check that all flake outputs evaluate with `nix flake check`
- run examples against a local checkout with `nix run . --override-input nixnet git+file:../..`

## Vendoring

- `vendor/` holds data generated from nixpkgs, so evaluating a config needs no import-from-derivation
- regenerate it with `nix develop --command ./vendor/update.sh` after bumping `flake.lock`; CI fails on a stale `vendor/`
