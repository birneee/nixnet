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
            if tb.nodes ? ${node.node} && tb.nodes.${node.node}.networking.interfaces ? ${node.iface} then
              tb.nodes.${node.node}.networking.interfaces.${node.iface}
            else
              null;
          ipv4s = map (a: "${a.address}/${toString a.prefixLength}") (nsIface.ipv4.addresses or [ ]);
          netemCfg = resolveNetem veth.netem (nsIface.netem or null);
          # Field order per model, matching the tc-netem(8) parameter order.
          # `attr` is the option name; `label` is the abbreviation shown in the diagram.
          lossFields = {
            state = [
              { attr = "p13"; label = "p13"; }
              { attr = "p31"; label = "p31"; }
              { attr = "p32"; label = "p32"; }
              { attr = "p23"; label = "p23"; }
              { attr = "p14"; label = "p14"; }
            ];
            gemodel = [
              { attr = "percent"; label = "p"; }
              { attr = "r"; label = "r"; }
              { attr = "h"; label = "h"; }
              { attr = "k"; label = "k"; }
            ];
          };
          lossLabel =
            loss:
            if loss.model == "random" then
              (lib.optionalString (loss.percent != null) "${builtins.toJSON loss.percent}%loss")
            else
              let
                fields = lib.filter (f: loss.${f.attr} != null) lossFields.${loss.model};
                paramStr = lib.concatMapStringsSep "," (
                  f: "${f.label}=${builtins.toJSON loss.${f.attr}}"
                ) fields;
              in
              "loss:${loss.model}(${paramStr})";
        in
        lib.concatStringsSep " " (
          lib.filter (s: s != "") (
            [ node.iface ]
            ++ ipv4s
            ++ lib.optionals (netemCfg != null) [
              (lib.optionalString (netemCfg.delayMs != null) "${toString netemCfg.delayMs}ms")
              (lib.optionalString (netemCfg.loss != null) (lossLabel netemCfg.loss))
              (lib.optionalString (netemCfg.rateMbit != null) "${toString netemCfg.rateMbit}Mbit/s")
            ]
          )
        );

      nsDecls = lib.mapAttrsToList (name: _: "    ${nodeId name}[${name}]") tb.nodes;

      ifaceDecls = lib.concatLists (
        map (
          veth:
          let
            idA = "${nodeId veth.a.iface}_${nodeId veth.a.node}";
            idB = "${nodeId veth.b.iface}_${nodeId veth.b.node}";
          in
          [
            "    ${idA}@{ shape: text, label: \"${mkIfaceLabel veth veth.a}\" }"
            "    ${idB}@{ shape: text, label: \"${mkIfaceLabel veth veth.b}\" }"
          ]
        ) (lib.attrValues tb.veths)
      );

      edgeDecls = map (
        veth:
        let
          idA = "${nodeId veth.a.iface}_${nodeId veth.a.node}";
          idB = "${nodeId veth.b.iface}_${nodeId veth.b.node}";
        in
        "    ${nodeId veth.a.node} --- ${idA} --- ${idB} --- ${nodeId veth.b.node}"
      ) (lib.attrValues tb.veths);
    in
    lib.concatStringsSep "\n" ([ "graph LR" ] ++ nsDecls ++ ifaceDecls ++ edgeDecls) + "\n";

  mkMermaid =
    networkConfig: pkgs.writeText "topology.mmd" (buildMermaid pkgs (evalConfig networkConfig).config);
  mkMermaidSvg =
    networkConfig:
    pkgs.runCommand "topology.svg"
      {
        buildInputs = [ pkgs.mermaid-cli ];
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
