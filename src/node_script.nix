{ pkgs, config }:
let
  lib = pkgs.lib;
  inherit (import ./common.nix { inherit pkgs; }) concatNonEmpty;
  name = config.name;
  nodes = config.nodes;

  # Write a script entry to a store path, preserving Nix string context.
  mkScriptFile =
    nodeName: scriptName: scriptCfg:
    pkgs.writeScript "${name}-script-${nodeName}-${scriptName}" ''
      #!${pkgs.bashNonInteractive}/bin/bash
      set -euo pipefail
      ${scriptCfg.exec}
    '';

  # Pre-computed script files per node: { nodeName -> { scriptName -> file } }
  nsScriptFiles = lib.mapAttrs (
    nodeName: nodeCfg:
    lib.mapAttrs (scriptName: scriptCfg: mkScriptFile nodeName scriptName scriptCfg) nodeCfg.scripts
  ) nodes;

  # Pre-computed script files for top-level experiment scripts: { scriptName -> file }
  tbScriptFiles = lib.mapAttrs (
    scriptName: scriptCfg: mkScriptFile "experiment" scriptName scriptCfg
  ) config.scripts;

  # All scripts as a flat list of { label, scriptPath, exec, scriptCfg }
  allScripts =
    lib.concatLists (
      lib.mapAttrsToList (
        nodeName: nodeCfg:
        lib.mapAttrsToList (scriptName: scriptCfg: {
          label = nodeName;
          scriptPath = "\"$(dirname \"$0\")/../nodes/${nodeName}/scripts/${scriptName}\"";
          exec = "jail enter ${nodeName} ";
          inherit scriptName scriptCfg;
        }) nodeCfg.scripts
      ) nodes
    )
    ++ lib.mapAttrsToList (scriptName: scriptCfg: {
      label = "experiment";
      scriptPath = "\"$(dirname \"$0\")/../scripts/${scriptName}\"";
      exec = "";
      inherit scriptName scriptCfg;
    }) config.scripts;

  # Launch scripts in parallel; mark awaited ones; skip foreground scripts
  launchScripts = lib.concatMap (
    {
      label,
      scriptName,
      scriptPath,
      exec,
      scriptCfg,
    }:
    lib.optional (!scriptCfg.foreground) (
      concatNonEmpty (
        [
          "("
          "  set +m"
          "  set -o pipefail"
          "  stdbuf -oL ${exec}${scriptPath} 2>&1 | sed 's/^/${label}| /'"
          ") &"
          "echo \"${label}| ${scriptName} (PID $!) started\""
          "PIDS[$!]=1"
        ]
        ++ lib.optional scriptCfg.await "WAIT_PIDS[$!]=1"
      )
    )
  ) allScripts;

  # Foreground scripts (run after background scripts are started)
  fgScripts = lib.concatMap (
    {
      label,
      scriptName,
      scriptPath,
      exec,
      scriptCfg,
    }:
    lib.optional scriptCfg.foreground (concatNonEmpty [
      "echo \"${label}| ${scriptName} started (foreground)\""
      "("
      "  ${exec}${scriptPath}"
      ")"
      "echo \"${label}| end foreground script\""
    ])
  ) allScripts;
in
{
  inherit
    nsScriptFiles
    tbScriptFiles
    launchScripts
    fgScripts
    ;
}
