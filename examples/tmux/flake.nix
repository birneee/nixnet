{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixnet.url = "github:birneee/nixnet";
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
        {
          packages.default = inputs'.nixnet.legacyPackages.mkTestbed {
            workDir = null;
            testbedPackages =
              with pkgs;
              lib.mkOptionDefault [
                tmux
                #todo the following should move to namespacePackages once proper nsenter works
                ethtool
                iperf3
                iputils
                netcat
                nmap
                tcpdump
                tshark
              ];
            namespaces = {
              client = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.1";
                    prefixLength = 24;
                  }
                ];
              };
              server = {
                networking.interfaces.eth0.ipv4.addresses = [
                  {
                    address = "10.0.0.2";
                    prefixLength = 24;
                  }
                ];
              };
            };
            scripts = [
              {
                foreground = true;
                exec = ''
                  SOCKET=/tmp/nixnet.sock
                  SESSION=nixnet
                  tmux -S $SOCKET -f ${./tmux.conf} new-session -d -s $SESSION -n "client" -- ip netns exec client bash
                  tmux -S $SOCKET new-window -t $SESSION -n "server" -- ip netns exec server bash
                  MENU_CMD='display-menu -T " New " -x 0 -y S \
                    "client" a "new-window -n client \"ip netns exec client bash\"" \
                    "server" b "new-window -n server \"ip netns exec server bash\"" \
                    "" \
                    "Exit Lab" q "confirm-before -p \"Exit session? (y/n)\" detach-client"'
                  tmux -S $SOCKET bind-key m "$MENU_CMD"
                  tmux -S $SOCKET bind-key -n MouseDown1StatusLeft "$MENU_CMD"
                  tmux -S /tmp/nixnet.sock attach-session -t nixnet
                '';
              }
            ];
            veths = [
              {
                netem.delayMs = 10;
                a = {
                  ns = "client";
                  iface = "eth0";
                };
                b = {
                  ns = "server";
                  iface = "eth0";
                };
              }
            ];
          };
        };
    };
}
