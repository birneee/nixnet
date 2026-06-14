{ pkgs, evalConfig }:
let
  inherit (import ./common.nix { inherit pkgs; }) resolveNetem;
  buildMermaid =
    pkgs: tb:
    let
      lib = pkgs.lib;
      # Sanitize names for use as Mermaid node IDs (hyphens not allowed)
      nodeId = name: lib.replaceStrings [ "-" " " "." ] [ "_" "_" "_" ] name;

      mkIfaceLabel =
        veth: node:
        let
          nsIface =
            if tb.namespaces ? ${node.ns} && tb.namespaces.${node.ns}.networking.interfaces ? ${node.iface} then
              tb.namespaces.${node.ns}.networking.interfaces.${node.iface}
            else
              null;
          ipv4s = map (a: "${a.address}/${toString a.prefixLength}") (nsIface.ipv4.addresses or [ ]);
          netemCfg = resolveNetem veth.netem (nsIface.netem or null);
        in
        lib.concatStringsSep " " (
          lib.filter (s: s != "") (
            [ node.iface ]
            ++ ipv4s
            ++ lib.optionals (netemCfg != null) [
              (lib.optionalString (netemCfg.delayMs != null) "${toString netemCfg.delayMs}ms")
              (lib.optionalString (netemCfg.lossPercent != null) "${builtins.toJSON netemCfg.lossPercent}%loss")
              (lib.optionalString (netemCfg.rateMbit != null) "${toString netemCfg.rateMbit}Mbit/s")
            ]
          )
        );

      nsDecls = lib.mapAttrsToList (name: _: "    ${nodeId name}[${name}]") tb.namespaces;

      ifaceDecls = lib.concatLists (
        map (
          veth:
          let
            idA = "${nodeId veth.a.iface}_${nodeId veth.a.ns}";
            idB = "${nodeId veth.b.iface}_${nodeId veth.b.ns}";
          in
          [
            "    ${idA}@{ shape: text, label: \"${mkIfaceLabel veth veth.a}\" }"
            "    ${idB}@{ shape: text, label: \"${mkIfaceLabel veth veth.b}\" }"
          ]
        ) tb.veths
      );

      edgeDecls = map (
        veth:
        let
          idA = "${nodeId veth.a.iface}_${nodeId veth.a.ns}";
          idB = "${nodeId veth.b.iface}_${nodeId veth.b.ns}";
        in
        "    ${nodeId veth.a.ns} --- ${idA} --- ${idB} --- ${nodeId veth.b.ns}"
      ) tb.veths;
    in
    lib.concatStringsSep "\n" ([ "graph LR" ] ++ nsDecls ++ ifaceDecls ++ edgeDecls) + "\n";

  mkMermaid =
    networkConfig: pkgs.writeText "topology.mmd" (buildMermaid pkgs (evalConfig networkConfig).config);
  mkMermaidSvg =
    networkConfig:
    pkgs.runCommand "topology.svg"
      {
        buildInputs = [ pkgs.nodePackages.mermaid-cli ];
        FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.liberation_ttf ]; };
        HOME = "/tmp";
      }
      ''
        mmdc -i ${mkMermaid networkConfig} -o $out
      '';
in
{
  inherit mkMermaid mkMermaidSvg;
}
