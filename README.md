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
          packages = with pkgs; [ coreutils iperf3 ];
          namespaces = {
            client.scripts = [{
              exec = "sleep 0.1; iperf3 -c 10.0.0.2";
              await = true;
            }];
            server.scripts = [{
              exec = "iperf3 -s";
            }];
          };
          links.veth0 = {
            netem.lossPercent = 1;
            a = { ns = "client"; ipv4 = "10.0.0.1/24"; };
            b = { ns = "server"; ipv4 = "10.0.0.2/24"; };
          };
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
- **Declarative** — namespaces, links, routes, and scripts defined in Nix
- **Reproducible** — all binaries pinned via nixpkgs
- **netem** — delay, loss, rate limiting per link or endpoint
- **Routing** — static routes, default routes, IP forwarding
- **ARP control** — disable ARP or prefill tables with peer MACs
- **Repeatable** — repeat with `sudo nix run . 1-5`; `{}` in `workDir` becomes a run index
- **Foreground scripts** — full terminal access for interactive tools
- **Sandboxing** — scripts are isolated with bubblewrap to prevent side effects
- **Automatic cleanup** — namespaces and processes cleaned up on exit
- **Mermaid diagrams** — topology diagram from config

## Comparison

| | nixnet | [mininet](https://mininet.org) | [containerlab](https://containerlab.dev) | manual scripts |
|---|---|---|---|---|
| **Config** | Nix | Python | YAML | bash |
| **Isolation** | network namespaces + bubblewrap | network namespaces | containers (Docker) | network namespaces |
| **Reproducibility** | ✓ | ✗ | partial | ✗ |
| **Real network stack** | ✓ | ✓ | ✓ | ✓ |
| **Cleanup on exit** | ✓ | ✓ | ✓ | manual |
| **Runtime dependency** | Nix | Python + OVS | Docker | iproute2 |
| **Dependency management** | nixpkgs | pip / manual | Docker images | manual |
| **Visualization** | mermaid diagram | ✓ | ✓ | ✗ |

nixnet is designed for lightweight, reproducible experiments that run real application binaries directly in network namespaces — no container overhead, no Python runtime, no daemon. Nix is the only runtime dependency; all other tools including iproute2 are fetched from nixpkgs. The output is a single self-contained shell script pinned to exact package versions via Nix.

## Examples

- [ping](examples/ping/) — two namespaces, one veth link with netem delay
- [iperf](examples/iperf/) — three namespaces with a forwarding router

## Options

### Top-level

| Option | Type | Default | Description |
|---|---|---|---|
| `name` | `str` | `"network-testbed"` | Name of the output binary. |
| `namespaces` | `attrs` | `{}` | Network namespaces to create. |
| `links` | `attrs` | `{}` | Veth link pairs connecting namespaces. |
| `packages` | `list` | `[]` | Packages prepended to PATH for all scripts in all namespaces. |
| `workDir` | `str \| null` | `null` | Working directory for the testbed. Created if absent. If the path contains `{}`, it is replaced at runtime with a two-digit zero-padded run index (default `00`), e.g. `"./out/{}"` with `sudo nix run . -- 5` uses `./out/05`. Pass a range to run multiple times: `sudo nix run . -- 1-5`. |
| `workDirEnsureEmpty` | `bool` | `false` | Abort if `workDir` is non-empty, preventing results from being overwritten. |
| `stdout` | `bool` | `true` | Print script output to the console, prefixed with the namespace name. Can be overridden per namespace. |
| `disableIpv6` | `bool` | `false` | Disable IPv6 in all namespaces. Can be overridden per namespace. |
| `arp` | `bool` | `true` | Enable ARP on all interfaces. Can be overridden per link or per endpoint. |
| `arpPrefill` | `bool` | `false` | Prefill ARP tables with peer MAC addresses at startup. Can be overridden per link or per endpoint. |
| `sandbox` | `bool` | `true` | Sandbox all scripts with bubblewrap: read-only filesystem access, write access limited to the script's working directory, isolated PID/UTS/IPC namespaces, cleared environment. Can be overridden per namespace or per script. |
| `inheritPath` | `bool` | `false` | Append the system PATH. Useful for accessing host tools not managed by Nix. |
| `preSetup` | `str` | `""` | Shell code to run before the setup phase (before namespaces and links are created). Runs as root. |
| `postSetup` | `str` | `""` | Shell code to run after the setup phase (after namespaces, links, and routes are configured). Runs as root. |
| `preRun` | `str` | `""` | Shell code to run before the run phase (before scripts are launched). Runs as root. |
| `postRun` | `str` | `""` | Shell code to run after the run phase (after all awaited scripts have exited). Runs as root. |

### Namespace options

| Option | Type | Default | Description |
|---|---|---|---|
| `ipv4Forward` | `bool` | `false` | Enable IPv4 forwarding. |
| `disableIpv6` | `bool \| null` | `null` | Disable IPv6. Overrides top-level `disableIpv6`. |
| `ipUnprivilegedPortStart` | `int` | `0` | Lowest port number that unprivileged users can bind to (`net.ipv4.ip_unprivileged_port_start`). |
| `defaultRoute` | `str \| null` | `null` | Default route gateway. |
| `routes` | `list` | `[]` | Static routes: `[{ subnet = "..."; via = "..."; }]`. |
| `packages` | `list` | `[]` | Packages prepended to PATH for all scripts in this namespace. |
| `scripts` | `list` | `[]` | Scripts to run in this namespace. Background scripts are launched in parallel; foreground scripts run sequentially after all background scripts are started. |
| `stdout` | `bool \| null` | `null` | Print script output to the console. Overrides top-level `stdout`. |
| `workDir` | `str \| null` | `null` | Working directory for all scripts in this namespace. Relative to the testbed `workDir` if not absolute. |
| `sandbox` | `bool \| null` | `null` | Sandbox all scripts in this namespace with bubblewrap. Overrides top-level `sandbox`. |

### Script options

| Option | Type | Default | Description |
|---|---|---|---|
| `exec` | `str` | — | Script to run. May be multi-line. |
| `await` | `bool` | `false` | Wait for this script to exit before stopping the testbed. Only applies to background scripts. |
| `foreground` | `bool` | `false` | Run this script in the foreground without output redirection. Runs after all background scripts are started. Use for interactive shells or tools that require a terminal. |
| `packages` | `list` | `[]` | Packages prepended to PATH for this script only. |
| `sandbox` | `bool \| null` | `null` | Sandbox this script with bubblewrap. Overrides namespace-level and top-level `sandbox`. |

### Link options

| Option | Type | Default | Description |
|---|---|---|---|
| `a` | `attrs` | — | First endpoint of the veth pair (see endpoint options below). |
| `b` | `attrs` | — | Second endpoint of the veth pair (see endpoint options below). |
| `netem` | `attrs \| null` | `null` | netem parameters applied to both endpoints. Individual fields can be overridden per endpoint. |
| `arp` | `bool \| null` | `null` | Enable ARP on both endpoints. Overrides top-level `arp`. |
| `arpPrefill` | `bool \| null` | `null` | Prefill ARP tables for both endpoints. Overrides top-level `arpPrefill`. |

### Link endpoint options

| Option | Type | Default | Description |
|---|---|---|---|
| `ns` | `str` | — | Namespace this endpoint belongs to. |
| `ipv4` | `str` | — | IPv4 address with prefix length, e.g. `"10.0.0.1/24"`. |
| `mtu` | `int` | `1500` | MTU for this interface. |
| `netem` | `attrs \| null` | `null` | netem parameters. Individual fields override the link-level `netem`. |
| `arp` | `bool \| null` | `null` | Enable ARP. Overrides link-level and top-level `arp`. |
| `arpPrefill` | `bool \| null` | `null` | Prefill ARP table with the peer's MAC address. Overrides link-level and top-level `arpPrefill`. |

### netem options

netem can be set at the link level or per endpoint. Endpoint fields override link-level fields.

| Option | Type | Default | Description |
|---|---|---|---|
| `delayMs` | `int \| null` | `null` | One-way delay in milliseconds. |
| `lossPercent` | `number \| null` | `null` | Packet loss percentage between 0 and 100, e.g. `1` for 1%. |
| `rateMbit` | `int \| null` | `null` | Rate limit in Mbit/s. |
| `limit` | `int \| null` | `null` | Queue size in packets. Takes precedence over `autoLimit`. |
| `autoLimit` | `bool \| null` | `null` | Compute queue limit from the bandwidth-delay product. Requires `delayMs` and `rateMbit`. |

## Execution Phases

The testbed runs in two phases:

1. **Setup** — creates network namespaces, veth pairs, assigns addresses, brings interfaces up, configures MTU, ARP, netem, and routes. Hook: `preSetup` / `postSetup`.
2. **Run** — launches all background scripts in parallel, then foreground scripts sequentially. Waits for scripts with `await = true` before exiting. Hook: `preRun` / `postRun`.

Cleanup (SIGINT to all child processes, namespace deletion) runs automatically on exit regardless of which phase it occurs in.

All hooks run as root — use with care.

## Notes

- Requires root (`sudo nix run`). When invoked via `sudo`, file operations (mkdir, output files) run as the original user (`$SUDO_USER`) so results are user-owned.
- Cleanup (SIGINT to all child processes, namespace deletion) happens automatically on exit.
- Use `await = true` on a background script to block the testbed from exiting until that script finishes.
- Use `foreground = true` for an interactive shell: `{ exec = "bash"; foreground = true; }`.

## Generate Mermaid Chart

```shell
nix shell nixpkgs#mermaid-cli # if not installed already
nix eval --raw .#legacyPackages.x86_64-linux.mermaid | mmdc -i -
```

live update

```shell
nix shell nixpkgs#mermaid-cli nixpkgs#watchexec # if not installed already
watchexec -e nix -- 'nix eval --raw .#legacyPackages.x86_64-linux.mermaid | mmdc -i -'
```

## Todos
- tmux for each namespace
- random netns postfix to multiple experiments can run at the same time
- easy nixnet cli tool
- nixnet mermaid --watch
- better IPv6 support

## Contributing

Contributions are welcome! Feel free to open issues or pull requests.
