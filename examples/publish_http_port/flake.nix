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
        { inputs', pkgs, lib, ... }:
        let
          nixnet = inputs'.nixnet.legacyPackages;
          python = pkgs.python312.withPackages (ps: [ ps.python-lorem ]);
          site = pkgs.runCommand "site" { nativeBuildInputs = [ python ]; } ''
            mkdir -p $out
            {
              python3 -c "
            import lorem, random
            random.seed(0)
            print('<p>' + lorem.get_paragraph(count=30).replace(chr(10), '</p><p>') + '</p>')
            "
              echo "<p><strong>EOF</strong></p>"
            } > $out/index.html
          '';

          config = {
            publishPorts = [ 8080 ];
            testbedPackages = pkgs.lib.mkOptionDefault [ pkgs.python3 ];
            scripts.web = {
              exec = "python3 -m http.server 8080 --bind 0.0.0.0 --directory ${site}";
              await = true;
            };

            nodes = {
              server = {
                packages = [ pkgs.python3 ];
                publishPorts = [ 8081 ];
                scripts.web.exec = "python3 -m http.server 8081 --bind 0.0.0.0 --directory ${site}";
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
              };
              client = {
                packages = [ pkgs.socat ];
                publishPorts = [ 8082 ];
                scripts.proxy.exec = "socat TCP-LISTEN:8082,fork,reuseaddr TCP:10.0.0.2:8081";
                networking.interfaces.veth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
              };
            };
            veths.veth0 = {
              netem = {
                delayMs = 100;
                rateMbit = 0.01;
              };
              a.node = "client";
              b.node = "server";
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
