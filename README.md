<image src="nixnet.svg" alt="nixnet" width="500"/>

# nixnet

Reproducible network experiments with a single command, on a single machine — no manual dependency installation, no manual setup, no manual cleanup, repeat anywhere at any time with exactly the same binaries. Define nodes, links, and scripts with the Nix language.

## Usage
1. If not available in your machine, install [Nix](https://nixos.org/download/) first.

2. Add nixnet as a [flake](https://nixos.wiki/wiki/Flakes) input and call `mkExperiment` from `legacyPackages`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";                # <-- Adding nixnet here
  };
  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];
      perSystem = { pkgs, inputs', ... }: {

        # EXPERIMENT: Define the virtual network lab
        packages.default = inputs'.nixnet.legacyPackages.mkExperiment {

          # Install standard tools and iperf3 on all virtual nodes
          nodePackages = with pkgs; [ coreutils iperf3 ];

          # TOPOLOGY: Define the nodes and what they do
          nodes = {
            client = {
              networking.interfaces.eth0.ipv4.addresses = [{ address = "10.0.0.1"; prefixLength = 24; }];
              scripts.main = { exec = "sleep 0.1; iperf3 -c 10.0.0.2"; await = true; };
            };
            server = {
              networking.interfaces.eth0.ipv4.addresses = [{ address = "10.0.0.2"; prefixLength = 24; }];
              scripts.main = { exec = "iperf3 -s"; };
            };
          };
          veths.eth0 = {
            netem.lossPercent = 1;
            a.node = "client";
            b.node = "server";
          };
        };
      };

    };
}
```

3. Run

```
nix run
```

## Features

- **Portable** — runs on any Linux machine with Nix installed
- **Declarative** — nodes, bridges, links, routes, and scripts defined in Nix
- **Reproducible** — all binaries pinned via nixpkgs
- **netem** — delay, loss, rate limiting per link or endpoint
- **Routing** — static routes, default routes, IP forwarding
- **ARP control** — disable ARP or prefill tables with peer MACs
- **Repeatable** — repeat with `sudo nix run . 1-5`; `{run}` in `workDir` becomes a run index
- **Foreground scripts** — full terminal access for interactive tools
- **Sandboxing** — experiments are isolated with Linux namespaces to prevent side effects
- **Host binds** — expose host directories, files and binaries inside node namespaces via `hostBind`
- **Automatic cleanup** — namespaces, files and processes cleaned up on exit
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

Performance evaluation is available [here](https://github.com/birneee/nixnet-evaluation).

## Examples

See [examples/](examples/) for inspiration. Examples can be run directly without cloning:

```shell
nix run 'github:birneee/nixnet?dir=examples/ping'
```

Show mermaid graph:
```shell
xdg-open $(nix build 'github:birneee/nixnet?dir=examples/ping#mermaid-svg' --no-link --print-out-paths)
```

## Options

[Full Option Docs](https://github.com/birneee/nixnet/wiki/nixnet-options-docs-latest)

## Execution Phases

The experiment testbed runs in two phases:

1. **Setup** — creates a testbed namespace, within creates node namespaces, applies sysctl settings, creates veth pairs, assigns addresses, brings interfaces up, configures MTU, ARP, netem, and routes. Hook: `preSetup` / `postSetup`.
2. **Run** — launches all background scripts in parallel, then foreground scripts sequentially. Waits for scripts with `await = true` before exiting. Hook: `preRun` / `postRun`.

Cleanup (SIGINT to all child processes, namespace deletion) runs automatically on exit regardless of which phase it occurs in.

All hooks run as root — use with care.

## Notes

- Root is not required for most features. Run with `nix run` as a regular user. Some features require root: eBPF/XDP programs need `CAP_NET_ADMIN` outside a user namespace — use `sudo nix run` for those.
- Cleanup (SIGINT to all child processes, namespace deletion) happens automatically on exit.
- Use `await = true` on a background script to block the experiment testbed from exiting until that script finishes.
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
xdg-open $(nix build .#mermaid-svg --no-link --print-out-paths)
```

> Tip: run `nix store gc` afterwards to clean up build artifacts.

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

## License

[MIT](LICENSE-MIT) or [Apache 2.0](LICENSE-APACHE), at your option.
