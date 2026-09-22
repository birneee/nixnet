{ pkgs, ... }:
let
  lib = pkgs.lib;

  jail_pkg = pkgs.callPackage ../jail/pkgs/jail.nix { };

  inherit (import ./lib.nix { inherit pkgs; }) evalConfig;

  mkExperiment =
    networkConfig:
    import ../src/testbed_jail.nix {
      inherit pkgs jail_pkg;
      config = (evalConfig networkConfig).config;
    };

  # keeps the testbed alive for the host-side check, else it exits once background scripts are launched
  sentinel = {
    exec = "sleep 10";
    await = true;
  };

  udpEcho = pkgs.writeText "udp_echo.py" ''
    import socket, sys
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", int(sys.argv[1])))
    while True:
        data, addr = s.recvfrom(64)
        s.sendto(data, addr)
  '';

  # server published via publishPorts entry, in the testbed's own netns or in node `server`
  mkTestbed =
    { entry, exec, inNode }:
    mkExperiment {
      imports = [
        (
          { name = "testbed"; workDir = null; }
          // (
            if inNode then
              {
                nodes.server = {
                  publishPorts = [ entry ];
                  packages = [ pkgs.python3 ];
                  scripts = { server.exec = exec; inherit sentinel; };
                };
              }
            else
              {
                publishPorts = [ entry ];
                scripts = { server.exec = exec; inherit sentinel; };
                testbedPackages = lib.mkOptionDefault [ pkgs.python3 ];
              }
          )
        )
      ];
    };

  # runs the testbed in the background, then `check` on the host
  mkHostTest =
    { name, testbed, runtimeInputs, check }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.coreutils ] ++ runtimeInputs;
      text = ''
        pass() { echo "PASS: $*"; }
        fail() { echo "FAIL: $*"; exit 1; }

        ${lib.getExe testbed} &
        TESTBED_PID=$!
        trap 'kill "$TESTBED_PID" 2>/dev/null || true; wait "$TESTBED_PID" 2>/dev/null || true' EXIT

        ${check}
        pass "host reached the server via hostPort"
      '';
    };

  mkHttpTest =
    { name, port, hostPort ? port, inNode ? false }:
    mkHostTest {
      inherit name;
      testbed = mkTestbed {
        entry = if hostPort == port then port else { inherit port hostPort; };
        exec = "python3 -m http.server ${toString port} --bind 0.0.0.0";
        inherit inNode;
      };
      runtimeInputs = [ pkgs.curl pkgs.gnugrep ];
      check = ''
        _ok=0
        for _i in $(seq 1 100); do
          if curl -4 -s -o /dev/null -w "%{http_code}" http://localhost:${toString hostPort}/ 2>/dev/null | grep -q 200; then
            _ok=1
            break
          fi
          sleep 0.1
        done
        [ "$_ok" -eq 1 ] || fail "host could not reach the published port"
      '';
    };

  mkUdpEchoTest =
    { name, port, inNode ? false }:
    mkHostTest {
      inherit name;
      testbed = mkTestbed {
        entry = { inherit port; protocol = "udp"; };
        exec = "python3 ${udpEcho} ${toString port}";
        inherit inNode;
      };
      runtimeInputs = [ pkgs.python3 ];
      check = ''
        python3 - <<'EOF' || fail "host got no UDP echo via the published port"
        import socket, time
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.2)
        for _ in range(50):
            s.sendto(b"ping", ("127.0.0.1", ${toString port}))
            try:
                if s.recvfrom(64)[0] == b"ping":
                    raise SystemExit(0)
            except socket.timeout:
                time.sleep(0.1)
        raise SystemExit(1)
        EOF
      '';
    };
in
{
  test-jail-publish-port-reachable = mkHttpTest { name = "test-jail-publish-port-reachable"; port = 8080; };
  test-jail-publish-port-node-reachable = mkHttpTest { name = "test-jail-publish-port-node-reachable"; port = 9090; inNode = true; };
  test-jail-publish-port-remapped-reachable = mkHttpTest { name = "test-jail-publish-port-remapped-reachable"; port = 8081; hostPort = 8180; };
  test-jail-publish-port-remapped-node-reachable = mkHttpTest { name = "test-jail-publish-port-remapped-node-reachable"; port = 9091; hostPort = 9190; inNode = true; };
  test-jail-publish-port-udp-echo = mkUdpEchoTest { name = "test-jail-publish-port-udp-echo"; port = 7070; };
  test-jail-publish-port-udp-node-echo = mkUdpEchoTest { name = "test-jail-publish-port-udp-node-echo"; port = 7071; inNode = true; };
}
