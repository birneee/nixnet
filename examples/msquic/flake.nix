{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
    msquic.url = "github:birneee/msquic";
    test-certs.url = "github:birneee/test-certs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      perSystem =
        { pkgs, inputs', ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          msquic = inputs'.msquic.packages.default;
          certs = inputs'.test-certs.packages.default;
          config = {
            arp = false;
            arpPrefill = true;
            namespacePackages = [
              msquic
              pkgs.coreutils
              pkgs.perf
              pkgs.flamegraph
            ];
            testbedPackages = pkgs.lib.mkOptionDefault [
              pkgs.perf
              pkgs.flamegraph
            ];
            postRun = ''
              perf script -i client/perf.data | stackcollapse-perf.pl | flamegraph.pl > client/flamegraph.svg
              perf script -i server/perf.data | stackcollapse-perf.pl | flamegraph.pl > server/flamegraph.svg
            '';
            namespaces = {
              client = {
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "193.167.0.100";
                      prefixLength = 16;
                    }
                  ];
                };
                scripts = [
                  {
                    exec = ''
                      sleep 0.1
                      ln -sf /dev/null 10GB
                      perf record -e cycles --call-graph fp -F 999 -o perf.data -- quicinterop \
                        -custom:193.167.100.100 \
                        -port:4433 \
                        -test:D \
                        -timeout:50000 \
                        -urls:https://193.167.100.100:4433/10GB >stdout 2>stderr
                      rm 10GB
                    '';
                    await = true;
                  }
                ];
              };
              server = {
                networking.interfaces.veth0.ipv4 = {
                  addresses = [
                    {
                      address = "193.167.100.100";
                      prefixLength = 16;
                    }
                  ];
                };
                scripts = [
                  {
                    exec = ''
                      mkdir -p /tmp/www
                      truncate -s 10G /tmp/www/10GB
                      perf record -e cycles --call-graph fp -F 999 -o perf.data -- quicinteropserver \
                        -listen:* \
                        -port:4433 \
                        -root:/tmp/www \
                        -file:${certs}/cert.pem \
                        -key:${certs}/key.pem \
                        -noexit >stdout 2>stderr
                    '';
                  }
                ];
              };
            };
            veths = [
              {
                a = {
                  ns = "client";
                  iface = "veth0";
                };
                b = {
                  ns = "server";
                  iface = "veth0";
                };
              }
            ];
          };
        in
        {
          packages.default = nixnet.mkTestbed config;
          packages.mermaid = nixnet.mkMermaid config;
          packages.mermaid-svg = nixnet.mkMermaidSvg config;
        };
    };
}
