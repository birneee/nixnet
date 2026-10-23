# cwnd over time, one line per iperf3 -J run, intervals with retransmits marked, and the BDP.
# usage: plot.py <out> <bdp kB> <run.json>...
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt

out, bdp, runs = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
plt.axhline(bdp, color="gray", linestyle="--", label="BDP")
for run in runs:
    samples = [i["streams"][0] for i in json.loads(Path(run).read_text())["intervals"]]
    time = [s["end"] for s in samples]
    cwnd = [s["snd_cwnd"] / 1e3 for s in samples]
    (line,) = plt.plot(time, cwnd, label=Path(run).stem)
    losses = [(t, c) for t, c, s in zip(time, cwnd, samples) if s["retransmits"] > 0]
    plt.plot(*zip(*losses), linestyle="none", marker="v", color=line.get_color())
plt.xlabel("time [s]")
plt.ylabel("cwnd [kB]")
plt.legend()
plt.savefig(out)
