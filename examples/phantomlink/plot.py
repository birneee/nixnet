"""Recreate Figure 5 of the PhantomLink paper (Ohs et al., ANRW '25).

usage: plot.py <client -J> <server -J> <scenario csv> <output pdf>
"""

import json
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd


def read_streams(path):
    """One row per interval, from an iperf3 -J run (single-stream tests only)."""
    intervals = json.load(open(path))["intervals"]
    return pd.json_normalize(intervals, record_path="streams")


def main():
    client_path, server_path, scenario_path, out_path = sys.argv[1:5]

    client = read_streams(client_path)
    server = read_streams(server_path)
    horizon = client["end"].max()

    scenario = pd.read_csv(scenario_path)
    scenario["time_s"] = scenario["Time[ms]"] / 1000
    scenario = scenario[scenario["time_s"] <= horizon]
    scenario["owd_ms"] = scenario["Delay[ms]"]
    scenario["rate_mbps"] = scenario["Btldr[Mbps]"]
    scenario["bdp_mb"] = scenario.rate_mbps * 1e6 * 2 * scenario.owd_ms / 1000 / 8 / 1e6

    client["owd_ms"] = client.rtt / 1000 / 2  # us -> ms, RTT -> OWD proxy
    client["cwnd_mb"] = client.snd_cwnd / 1e6
    retransmits = client[client.retransmits > 0]
    server["rate_mbps"] = server.bits_per_second / 1e6

    fig, (ax_owd, ax_rate, ax_cwnd) = plt.subplots(3, 1, figsize=(9, 7.5), sharex=True)

    ax_owd.step(scenario.time_s, scenario.owd_ms, where="post", color="gray", linestyle="--", label="Predicted OWD")
    ax_owd.plot(client.end, client.owd_ms, label="RTT/2")
    ax_owd.set_ylabel("One-way Delay [ms]")

    ax_rate.step(scenario.time_s, scenario.rate_mbps, where="post", color="gray", linestyle="--", label="Bottleneck Data Rate")
    ax_rate.plot(server.end, server.rate_mbps, label="DR Server")
    ax_rate.set_ylabel("Data Rate [Mbit/s]")

    ax_cwnd.step(scenario.time_s, scenario.bdp_mb, where="post", color="gray", linestyle="--", label="BDP")
    ax_cwnd.plot(client.end, client.cwnd_mb, label="CWND")
    if not retransmits.empty:
        ax_cwnd.plot(retransmits.end, retransmits.cwnd_mb, linestyle="none", marker="v", label="retransmits")
    ax_cwnd.set_ylabel("CWND [MB]")
    ax_cwnd.set_xlabel("Time [s]")
    ax_cwnd.set_xlim(0, horizon)

    for ax in (ax_owd, ax_rate, ax_cwnd):
        ax.set_ylim(bottom=0)
        ax.legend(fontsize=8, loc="upper left")
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path)
    print(f"testbed| wrote {out_path}")


if __name__ == "__main__":
    main()
