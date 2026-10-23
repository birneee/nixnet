{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = inputs.nixnet.supportedSystems;
      perSystem =
        { pkgs, inputs', ... }:
        let
          inherit (pkgs) lib;
          nixnet = inputs'.nixnet.legacyPackages;

          # in the XanMod kernel, where bbr is BBRv3
          congestionControls = [
            "reno"
            "cubic"
            "vegas"
            "bbr"
          ];

          # a 50 Mbit/s bottleneck, 50 ms RTT, about one BDP of buffer, 0.1% random loss
          netem = {
            delayMs = 25;
            rateMbit = 50;
            limit = 300;
            lossPercent = 0.1;
          };
          bdpKB = netem.rateMbit * 1000 / 8 * 2 * netem.delayMs / 1000.0;

          pythonWithPlotting = pkgs.python3.withPackages (ps: [ ps.matplotlib ]);

          config = {
            # runs in the testbed workdir
            postRun = ''
              ${pythonWithPlotting}/bin/python3 ${./plot.py} plot.pdf ${toString bdpKB} \
                ${lib.concatMapStringsSep " " (cc: "sender/${cc}.json") congestionControls}
            '';
            nodes = {
              # BBRv3 is out of tree, so the sender needs a kernel of its own
              sender = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
                vm =
                  { pkgs, ... }:
                  {
                    boot = {
                      kernelPackages = pkgs.linuxPackages_xanmod;
                      # each run starts fresh, not from the ssthresh and RTT the previous one cached
                      kernel.sysctl."net.ipv4.tcp_no_metrics_save" = 1;
                    };
                    environment.systemPackages = [ pkgs.iperf3 ];
                    systemd = {
                      # MTU-sized packets, so netem's limit and loss count packets, not 64 KB segments
                      network.links.eth0.linkConfig = {
                        TCPSegmentationOffload = false;
                        TCP6SegmentationOffload = false;
                        GenericSegmentationOffload = false;
                      };
                      services.iperf = nixnet.vmService {
                        # -J for snd_cwnd and retransmits, every 100 ms; a pause drains the queue
                        exec = ''
                          for cc in ${toString congestionControls}; do
                            iperf3 -c 10.0.0.2 -C $cc -t 5 -i 0.1 -J > ./$cc.json
                            sleep 1
                          done
                        '';
                        await = true;
                      };
                    };
                  };
              };
              receiver = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
                packages = [ pkgs.iperf3 ];
                scripts.iperf.exec = "iperf3 -s > ./stdout 2>&1";
              };
            };
            veths.eth0 = {
              inherit netem;
              mtu = 1500;
              a.node = "sender";
              b.node = "receiver";
            };
          };
        in
        {
          packages.default = nixnet.mkExperiment config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
