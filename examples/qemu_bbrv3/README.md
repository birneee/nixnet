A sender VM runs iperf3 to a receiver node once per TCP congestion control (reno, cubic, vegas, bbr) over a 50 Mbit/s bottleneck with 50 ms RTT, about one BDP of buffer and 0.1% random loss. The VM runs the XanMod kernel, whose bbr is BBRv3. BBRv3 changes TCP itself, so it is neither in mainline Linux nor a loadable module, only possible in a VM.

```
nix run
```

Each run lasts 5 s. iperf3 samples cwnd and retransmits every 100 ms into `out/{run}/sender/<cc>.json`, a `postRun` hook plots the cwnd of all runs, losses marked, into `out/{run}/plot.pdf`.
