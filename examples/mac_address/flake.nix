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
        {
          inputs',
          pkgs,
          lib,
          ...
        }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          config =
            # Use module function to resolve static macAddresses directly
            { config, ... }:
            {
              assertions = [
                {
                  assertion = config.nodes.recv_runtime.networking.interfaces.eth-runtime.macAddress == null;
                  message = "recv_runtime: macAddress should stay null (kernel-assigned)";
                }
                {
                  assertion = config.nodes.recv_det.networking.interfaces.eth-det.macAddress == "02:00:00:00:00:00";
                  message = "recv_det: deterministic macAddress should be index 0";
                }
                {
                  assertion =
                    config.nodes.recv_manual.networking.interfaces.eth-manual.macAddress == "02:00:00:aa:bb:cc";
                  message = "recv_manual: macAddress should be its own explicit value";
                }
                {
                  # Tests MAC address collision detection.
                  assertion =
                    !(builtins.tryEval
                      (nixnet.mkExperiment {
                        deterministicMacAddress = true;
                        veths.eth1 = {
                          a.node = "collide-a";
                          b.node = "collide-b";
                        };
                        nodes.collide-b.networking.interfaces.eth1 = {
                          macAddress = "02:00:00:00:00:00";
                          deterministicMacAddress = false;
                        };
                      }).drvPath
                    ).success;
                  message = "expected MAC collision to be rejected, wasn't";
                }
              ];
              nodePackages = lib.mkOptionDefault (
                with pkgs;
                [
                  netsniff-ng # trafgen
                  tcpdump
                ]
              );
              bridges = [ "br0" ];
              veths = {
                eth-sender = {
                  a.node = "sender";
                  b.node = "br0";
                };
                eth-runtime = {
                  a.node = "recv_runtime";
                  b.node = "br0";
                };
                eth-manual = {
                  a.node = "recv_manual";
                  b.node = "br0";
                };
                eth-det = {
                  a.node = "recv_det";
                  b.node = "br0";
                };
              };
              nodes = {
                sender.scripts.main = {
                  exec = ''
                    sleep 1

                    trafgen -o eth-sender -n 1 '{ eth(da=${config.nodes.recv_manual.networking.interfaces.eth-manual.macAddress}, type=0x88b5), "hello-manual" }'

                    trafgen -o eth-sender -n 1 '{ eth(da=${config.nodes.recv_det.networking.interfaces.eth-det.macAddress}, type=0x88b5), "hello-det" }'
                  '';
                  await = true;
                };
                recv_manual = {
                  networking.interfaces.eth-manual.macAddress = "02:00:00:aa:bb:cc";
                  scripts.main = {
                    exec = ''
                      timeout 5 tcpdump -i eth-manual -c 1 -A 'ether proto 0x88b5' 2>/dev/null | grep -q "hello-manual"
                      echo "CONTENT VERIFIED: hello-manual"
                    '';
                    await = true;
                  };
                };
                recv_det = {
                  networking.interfaces.eth-det.deterministicMacAddress = true;
                  scripts.main = {
                    exec = ''
                      timeout 5 tcpdump -i eth-det -c 1 -A 'ether proto 0x88b5' 2>/dev/null | grep -q "hello-det"
                      echo "CONTENT VERIFIED: hello-det"
                    '';
                    await = true;
                  };
                };
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
