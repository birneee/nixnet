Runs [PhantomLink](https://github.com/robinohs/phantomlink) link shaper between two nodes, replaying a synthetic `scenario.csv` under iperf3 traffic. nixnet owns the whole topology, so only PhantomLink's `start` is used, with its own namespace setup, kernel parameters and thread priority turned off via flags.

```
nix run
```

iperf3 reports json stats.
A `postRun` hook plots the stats `out/{run}/plot.pdf` — recreating Figure 5 of the [PhantomLink paper](https://doi.org/10.1145/3744200.3744758).
