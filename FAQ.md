# FAQ

## Is the NixNet schema stable?
No, NixNet is built to evolve, but your experiment pins its exact NixNet version, and removed options fail with a hint naming their replacement.

## When will there be a NixNet 1.0?
Maybe never, NixNet keeps evolving, but the main branch is intended to be stable enough for your experiments.

## Is NixNet deterministic?
No, the build is reproducible because the experiment is the same input-addressed derivation, but the runtime (timing, scheduling, netem's randomness) is not deterministic.

## Does this only run on NixOS?
No, it runs on any Linux with namespace support and Nix with the `flakes` and `nix-command` features enabled, including Linux VMs on macOS and Windows.

## Can I reproduce any experiment?
Mostly, the experiment's `flake.lock` pins every dependency, though pinned sources can disappear upstream, only the setup is reproduced, not the exact results, and host kernel and hardware are recorded in `run.json` when `workDir` is set.

## Do I need root?
No, `nix run` works as a regular user, only features like eBPF/XDP that need `CAP_NET_ADMIN` outside a user namespace require `sudo nix run`.

## Why does it fail on Ubuntu?
Ubuntu's AppArmor restricts unprivileged user namespaces by default, allow them with `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.

## How do I pin a NixNet version?
Commit your experiment's `flake.lock`, or reference a specific commit in the input, e.g. `github:birneee/nixnet/<rev>`.

## How does it compare to alternatives?
NixNet is more lightweight than containers and VMs, and unlike Mininet or plain network namespaces it also isolates each node's runtime (filesystem, processes, IPC, hostname, users) and runs each experiment in its own testbed namespace, so no state leaks between host and experiment or between experiments that could invalidate your results.

## How do I cite NixNet?
Cite the ANRW '26 paper:
```bibtex
@inproceedings{spies2026nixnet,
  author = {Spies, Benedikt and Bosk, Marcin and Mendes, Paulo and Ott, J{\"o}rg},
  title = {NixNet: Reproducible Virtual Network Experiments},
  booktitle = {Proceedings of the 2026 Applied Networking Research Workshop},
  series = {ANRW '26},
  pages = {60--66},
  publisher = {ACM},
  year = {2026},
  doi = {10.1145/3822163.3827939}
}
```

## Why build on Nix?
Nix declaratively fetches and builds every dependency in isolation from pinned inputs, drawing on the large nixpkgs package collection, so an experiment runs with a single command and the same inputs on any machine.
