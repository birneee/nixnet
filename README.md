<image src="nixnet.svg" alt="nixnet" width="500"/>

# nixnet

Reproducible network experiments with a single command, on a single machine — no manual dependency installation, no manual setup, no manual cleanup, repeat anywhere at any time with exactly the same binaries. Define network namespaces, links, and scripts with the Nix language.

## Usage

Add nixnet as a flake input and call `mkTestbed` from `legacyPackages`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
  };
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      perSystem = { pkgs, inputs', ... }: {
        packages.default = inputs'.nixnet.legacyPackages.mkTestbed {
          namespacePackages = with pkgs; [ coreutils iperf3 ];
          namespaces = {
            client = {
              networking.interfaces.eth0.ipv4.addresses = [{ address = "10.0.0.1"; prefixLength = 24; }];
              scripts = [{ exec = "sleep 0.1; iperf3 -c 10.0.0.2"; await = true; }];
            };
            server = {
              networking.interfaces.eth0.ipv4.addresses = [{ address = "10.0.0.2"; prefixLength = 24; }];
              scripts = [{ exec = "iperf3 -s"; }];
            };
          };
          veths = [{
            netem.lossPercent = 1;
            a = { ns = "client"; iface = "eth0"; };
            b = { ns = "server"; iface = "eth0"; };
          }];
        };
      };
    };
}
```

Run with:

```
sudo nix run
```

## Features

- **Portable** — runs on any Linux machine with Nix installed
- **Declarative** — namespaces, bridges, links, routes, and scripts defined in Nix
- **Reproducible** — all binaries pinned via nixpkgs
- **netem** — delay, loss, rate limiting per link or endpoint
- **Routing** — static routes, default routes, IP forwarding
- **ARP control** — disable ARP or prefill tables with peer MACs
- **Repeatable** — repeat with `sudo nix run . 1-5`; `{}` in `workDir` becomes a run index
- **Foreground scripts** — full terminal access for interactive tools
- **Sandboxing** — scripts are isolated with Linux namespaces to prevent side effects; configurable filesystem, environment, and PATH sharing
- **Automatic cleanup** — namespaces and processes cleaned up on exit
- **Mermaid diagrams** — topology diagram from config

## Comparison

| | nixnet | [mininet](https://mininet.org) | [containerlab](https://containerlab.dev) | manual scripts |
|---|---|---|---|---|
| **Config** | Nix | Python | YAML | bash |
| **Isolation** | mnt, pid, net, ipc, uts, user namespaces | net namespaces | Docker | net namespaces |
| **Reproducibility** | ✓ | ✗ | partial | ✗ |
| **Real network stack** | ✓ | ✓ | ✓ | ✓ |
| **Cleanup on exit** | ✓ | ✓ | ✓ | manual |
| **Runtime dependency** | Nix | Python + OVS | Docker | iproute2 |
| **Dependency management** | nixpkgs | pip / manual | Docker images | manual |
| **Visualization** | mermaid diagram | ✓ | ✓ | ✗ |

nixnet is designed for lightweight, reproducible experiments that run real application binaries directly in network namespaces — no container overhead, no Python runtime, no daemon. Nix is the only runtime dependency; all other tools including iproute2 are fetched from nixpkgs. The output is a single self-contained shell script pinned to exact package versions via Nix.

## Examples

See [examples/](examples/) for inspiration. Examples can be run directly without cloning:

```shell
nix run 'github:birneee/nixnet?dir=examples/ping'
```

Show mermaid graph:
```shell
nix build 'github:birneee/nixnet?dir=examples/ping#mermaid-svg' && xdg-open result
```

## Options

[Full Option Docs](https://github.com/birneee/nixnet/wiki/nixnet-options-docs-latest)

## Execution Phases

The testbed runs in two phases:

1. **Setup** — creates network namespaces, applies sysctl settings, creates veth pairs, assigns addresses, brings interfaces up, configures MTU, ARP, netem, and routes. Hook: `preSetup` / `postSetup`.
2. **Run** — launches all background scripts in parallel, then foreground scripts sequentially. Waits for scripts with `await = true` before exiting. Hook: `preRun` / `postRun`.

Cleanup (SIGINT to all child processes, namespace deletion) runs automatically on exit regardless of which phase it occurs in.

All hooks run as root — use with care.

## Notes

- Root is not required for most features. Run with `nix run` as a regular user. Some features require root: eBPF/XDP programs need `CAP_NET_ADMIN` outside a user namespace — use `sudo nix run` for those.
- Cleanup (SIGINT to all child processes, namespace deletion) happens automatically on exit.
- Use `await = true` on a background script to block the testbed from exiting until that script finishes.
- Use `foreground = true` for an interactive shell: `{ exec = "bash"; foreground = true; }`.

## Generate Option Docs

```shell
nix build .#nixnet-option-docs
cat result
```

## Generate Mermaid Chart

```shell
nix build .#mermaid && cat result
```

Open as SVG:

```shell
nix build .#mermaid-svg && xdg-open result
```

> Tip: run `nix store gc` afterwards to clean up build artifacts.

## Todos
- tmux for each namespace
- random netns postfix to multiple experiments can run at the same time
- easy nixnet cli tool
- nixnet mermaid --watch

## LSP Configuration

For option documentation and completions with [nixd](https://github.com/nix-community/nixd/blob/main/nixd/docs/configuration.md), add the following to your nixd settings:

```json
{
  "options": {
    "nixnet": {
      "expr": "(builtins.getFlake (toString ./.)).inputs.nixnet.legacyPackages.x86_64-linux.options"
    }
  }
}
```

## Contributing

Contributions are welcome! Feel free to open issues or pull requests.
