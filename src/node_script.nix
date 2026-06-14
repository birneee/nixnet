{ pkgs, tb }:
let
  lib = pkgs.lib;
  inherit (import ./common.nix { inherit pkgs; }) concatNonEmpty;
  name = tb.name;
  namespaces = tb.namespaces;

  # Write a script entry to a store path, preserving Nix string context.
  mkScriptFile =
    nsName: idx: scriptCfg:
    pkgs.writeScript "${name}-script-${nsName}-${toString idx}" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail
      ${scriptCfg.exec}
    '';

  # Pre-computed script files per namespace: { nsName -> [file0, file1, ...] }
  nsScriptFiles = lib.mapAttrs (
    nsName: nsCfg: lib.imap0 (idx: scriptCfg: mkScriptFile nsName idx scriptCfg) nsCfg.scripts
  ) namespaces;

  # Pre-computed script files for top-level testbed scripts: [file0, file1, ...]
  tbScriptFiles = lib.imap0 (idx: scriptCfg: mkScriptFile "testbed" idx scriptCfg) tb.scripts;

  # All scripts as a flat list of { label, scriptPath, exec, scriptCfg }
  allScripts =
    lib.concatLists (
      lib.mapAttrsToList (
        name: nsCfg:
        lib.imap0 (idx: scriptCfg: {
          label = name;
          scriptPath = "\"$(dirname \"$0\")/../namespaces/${name}/scripts/${toString idx}\"";
          exec = "jail enter ${name} ";
          inherit scriptCfg;
        }) nsCfg.scripts
      ) namespaces
    )
    ++ lib.imap0 (idx: scriptCfg: {
      label = "testbed";
      scriptPath = "\"$(dirname \"$0\")/../scripts/${toString idx}\"";
      exec = "";
      inherit scriptCfg;
    }) tb.scripts;

  # Launch scripts in parallel; mark awaited ones; skip foreground scripts
  launchScripts = lib.concatMap (
    {
      label,
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
          "echo \"${label}| PID $! started\""
          "PIDS+=($!)"
        ]
        ++ lib.optional scriptCfg.await "WAIT_PIDS+=($!)"
      )
    )
  ) allScripts;

  # Foreground scripts (run after background scripts are started)
  fgScripts = lib.concatMap (
    {
      label,
      scriptPath,
      exec,
      scriptCfg,
    }:
    lib.optional scriptCfg.foreground (concatNonEmpty [
      "echo \"${label}| start foreground script\""
      "("
      "  ${exec}${scriptPath}"
      ")"
      "echo \"${label}| end foreground script\""
    ])
  ) allScripts;
in
{
  inherit nsScriptFiles tbScriptFiles launchScripts fgScripts;
}
