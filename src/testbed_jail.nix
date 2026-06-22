{
  pkgs,
  jail_pkg,
  config,
}:
let
  lib = pkgs.lib;
  nodes = config.nodes;
  workDir = config.workDir;
  name = config.name;
  hasTemplate = workDir != null && lib.hasInfix "{run}" workDir;
  common = import ./common.nix { inherit pkgs; };
  gen = import ./testbed_script.nix { inherit pkgs config; };
in
pkgs.stdenv.mkDerivation {
  pname = name;
  version = "0";
  dontUnpack = true;
  strictDeps = true;
  nativeBuildInputs = [ ];
  installPhase = ''
    mkdir -p $out/bin
  ''
  + lib.concatStrings (
    lib.mapAttrsToList (
      nodeName: nodeCfg:
      lib.concatStrings (
        lib.mapAttrsToList (
          scriptName: _scriptCfg:
          let
            scriptFile = gen.nodeScriptFiles.${nodeName}.${scriptName};
          in
          ''
            mkdir -p $out/nodes/${nodeName}/scripts
            install -m 0755 ${scriptFile} $out/nodes/${nodeName}/scripts/${scriptName}
          ''
        ) nodeCfg.scripts
      )
    ) nodes
  )
  + lib.concatStrings (
    lib.mapAttrsToList (
      scriptName: _scriptCfg:
      let
        scriptFile = gen.tbScriptFiles.${scriptName};
      in
      ''
        mkdir -p $out/scripts
        install -m 0755 ${scriptFile} $out/scripts/${scriptName}
      ''
    ) config.scripts
  )
  + (
    let
      anyNodeShareWayland = lib.any (node: node.shareWayland) (lib.attrValues nodes);
      anyNodeSharePipeWire = lib.any (node: node.sharePipeWire) (lib.attrValues nodes);
      jailFlags = [
        ''--setenv "PATH=$PATH"''
      ]
      ++ lib.optional (config.shareWayland || anyNodeShareWayland) "--wayland"
      ++ lib.optionals (config.sharePipeWire || anyNodeSharePipeWire) [
        ''--ro-bind "$XDG_RUNTIME_DIR/''${PIPEWIRE_REMOTE:-pipewire-0}" "/run/user/0/pipewire-0"''
        ''--ro-bind "$XDG_RUNTIME_DIR/pulse/native" "/run/user/0/pulse/native"''
        ''--setenv "XDG_RUNTIME_DIR=/run/user/0"''
        ''--setenv "PIPEWIRE_REMOTE=pipewire-0"''
        ''--setenv "PULSE_SERVER=unix:/run/user/0/pulse/native"''
      ]
      ++ map (
        binding:
        if binding.readonly then
          "--ro-bind '${binding.path}' '/ro-host${binding.path}'"
        else
          "--bind '${binding.path}' '/host${binding.path}'"
      ) gen.tbAutoHostBinds
      ++ lib.optionals (workDir != null) [
        ''--bind "$_WORK_DIR" /pwd''
        "--chdir /pwd"
      ];
    in
    ''
      install -m 0755 ${pkgs.writeScript name ''
        #!${pkgs.bashNonInteractive}/bin/bash
        set -euo pipefail

        _PATH="" # clear path
        ${common.mkPathLines (config.testbedPackages ++ [ jail_pkg ])}
        export PATH="$_PATH"

        ${common.concatNonEmpty [
          (
            if hasTemplate then
              ''
                IFS='-' read -r _START _END <<< "''${1:-}"
                if [ -n "$_END" ]; then
                  for _RUN_NUM in $(seq "$_START" "$_END"); do
                    "$0" "$_RUN_NUM" || true
                  done
                  exit 0
                fi
                _RUN_NUM=''${_START:-0}
                _WORK_DIR_TPL='${workDir}'
                _WORK_DIR="''${_WORK_DIR_TPL//\{run\}/$(printf "%02d" "$_RUN_NUM")}"
                while [ -z "''${1:-}" ] && [ -e "$_WORK_DIR" ]; do
                  _RUN_NUM=$((_RUN_NUM+1))
                  _WORK_DIR="''${_WORK_DIR_TPL//\{run\}/$(printf "%02d" "$_RUN_NUM")}"
                done
              ''
            else
              lib.optionalString (workDir != null) ''
                _WORK_DIR='${workDir}'
              ''
          )
          (lib.optionalString (workDir != null) ''
            mkdir -p "$_WORK_DIR"
            echo "testbed| workdir: $(realpath "$_WORK_DIR")"'')
        ]}

        _SELF="$(readlink -f "$0")"
        exec jail exec \
          ${lib.concatStringsSep " \\\n  " (jailFlags ++ [ "\"$(dirname \"$_SELF\")/.${name}-wrapped\"" ])}
      ''} $out/bin/${name}
      install -m 0755 ${pkgs.writeScript "${name}-wrapped" gen.scriptText} $out/bin/.${name}-wrapped
    ''
  );
  meta.mainProgram = name;
}
