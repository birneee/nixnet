# A node's VM, see `nodes.<name>.vm`: its interfaces wired to the VM's NICs, the script running it,
# the `vmService` helper, and the assertions on what a node with a VM may set.
# todo arpPrefill of the VM's own interfaces, rejected for now
{ pkgs }:
let
  lib = pkgs.lib;
  ip = "${pkgs.iproute2}/bin/ip";
  tc = "${pkgs.iproute2}/bin/tc";
  awk = "${pkgs.gawk}/bin/awk";
  # fixed PCI slots for the NICs, the lower ones left to QEMU's own devices
  pciSlots = lib.range 16 31;

  # a NIC per interface, at a fixed PCI slot, by which the VM names it after the interface
  mkNics =
    node:
    lib.imap0 (index: iface: {
      inherit iface;
      inherit (node.networking.interfaces.${iface}) mtu;
      tap = "vmtap${toString index}";
      slot = lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (lib.elemAt pciSlots index)));
    }) (lib.attrNames node.networking.interfaces);

  mkSystem =
    name: node:
    pkgs.nixos (
      import ./vm_nixos.nix {
        inherit lib name node;
        nics = mkNics node;
      }
    );
in
{
  inherit mkSystem;

  # a service of the VM like a node's script: once the network is online, in the node's
  # workDir, with the VM's packages; awaited ones end the VM, see vm_nixos.nix
  vmService =
    {
      exec,
      await ? false,
    }:
    {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [ "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        WorkingDirectory = "/pwd";
      };
      script = exec;
      unitConfig = lib.optionalAttrs await { X-NixnetAwait = true; };
    };

  assertions =
    # a node and an interface with nothing set, see testbed_options.nix
    { emptyNode, emptyInterface }:
    nodes:
    let
      # options with an effect on a VM node, any other set is rejected
      compatibleNodeOptions = [
        "vm"
        "networking"
        # the VM's /pwd
        "workDir"
        "layer2Transparent"
      ];
      compatibleInterfaceOptions = [
        "ipv4"
        "ipv6"
        "mtu"
        "macAddress"
        "deterministicMacAddress"
        "netem"
      ];
      # options set in `value`, i.e. other than in `empty`, and not `compatible`;
      # functions never compare equal, an option holding one always counts as set
      incompatibleOptions =
        compatible: empty: value:
        lib.filter (option: !lib.elem option compatible && value.${option} != empty.${option}) (
          lib.attrNames (removeAttrs empty [ "_module" ])
        );
    in
    lib.concatLists (
      lib.mapAttrsToList (
        name: node:
        let
          rejectedOptions =
            map (option: "nodes.${name}.${option}") (incompatibleOptions compatibleNodeOptions emptyNode node)
            ++ lib.concatLists (
              lib.mapAttrsToList (
                iface: ifaceCfg:
                map (option: "nodes.${name}.networking.interfaces.${iface}.${option}") (
                  incompatibleOptions compatibleInterfaceOptions emptyInterface ifaceCfg
                )
              ) node.networking.interfaces
            );
          interfaceCount = lib.length (lib.attrNames node.networking.interfaces);
          # gateways without an interface: networkd needs one, guessed only for a single NIC,
          # see vm_nixos.nix
          unboundGateways =
            lib.filter
              (gateway: node.networking.${gateway} != null && node.networking.${gateway}.interface == null)
              [
                "defaultGateway"
                "defaultGateway6"
              ];
        in
        lib.optionals (node.vm != null) (
          [
            {
              assertion = interfaceCount <= lib.length pciSlots;
              message = "nixnet: `nodes.${name}.vm` has ${toString interfaceCount} interfaces, at most ${toString (lib.length pciSlots)} fit its free PCI slots";
            }
          ]
          ++ map (gateway: {
            assertion = interfaceCount == 1;
            message = "nixnet: `nodes.${name}.networking.${gateway}.interface` must be set, its VM has ${toString interfaceCount} interfaces";
          }) unboundGateways
          ++ map (option: {
            assertion = false;
            message = "nixnet: `${option}` has no effect with `nodes.${name}.vm`, unset it";
          }) rejectedOptions
        )
      ) nodes
    );

  # for the node's tap devices, forwarded by the host kernel (vhost-net), and hardware
  # virtualization, all required
  jailFlags = [
    "--bind /dev/net/tun /dev/net/tun"
    "--bind /dev/vhost-net /dev/vhost-net"
    "--bind /dev/kvm /dev/kvm"
  ];

  # the script running the VM, every frame redirected between each interface and its NIC's tap
  # device, both ways, and whether it is awaited
  mkVm =
    name: node:
    let
      nics = mkNics node;
      system = mkSystem name node;
      awaited = system.config.systemd.services.nixnet-poweroff.enable;

      redirect = from: to: ''
        ${tc} qdisc add dev ${from} ingress
        ${tc} filter add dev ${from} ingress matchall action mirred egress redirect dev ${to}
      '';
      disableIpv6 = dev: "echo 1 > /proc/sys/net/ipv6/conf/${dev}/disable_ipv6";

      wireNic = nic: ''
        ${ip} tuntap add dev ${nic.tap} mode tap
        ${disableIpv6 nic.iface}
        ${disableIpv6 nic.tap}
        ${ip} link set ${nic.tap}${lib.optionalString (nic.mtu != null) " mtu ${toString nic.mtu}"} up
        ${redirect nic.iface nic.tap}${redirect nic.tap nic.iface}'';

      qemuNicArgs =
        nic:
        "-netdev tap,id=${nic.tap},ifname=${nic.tap},script=no,downscript=no,vhost=on"
        + " -device virtio-net-pci,netdev=${nic.tap},addr=0x${nic.slot}"
        # the node's /sys shows the testbed's interfaces, ip the node's
        + ",mac=$(${ip} -br link show dev ${nic.iface} | ${awk} '{print $3}')";
    in
    {
      inherit awaited;
      script = ''
        ${lib.concatMapStrings wireNic nics}
        # run-nixos-vm's own TMPDIR, whose xchg is the VM's /tmp/xchg
        export TMPDIR="$(mktemp -d)" USE_TMPDIR=1
        # stdin from /dev/null: in a background job, QEMU's terminal setup would stop it;
        # the console to qemu.log, QEMU's own errors stay on stderr
        NIXNET_NIC_ARGS="${lib.concatMapStringsSep " " qemuNicArgs nics}" \
        NIXNET_PWD="$PWD" \
          ${lib.getExe system.vm} < /dev/null > qemu.log
        ${lib.optionalString awaited ''
          # the awaited services' exit status, see vm_nixos.nix
          if [ ! -e "$TMPDIR/xchg/exit-status" ]; then
            echo "the VM ended before its awaited services finished, see qemu.log" >&2
            exit 1
          fi
          exit "$(< "$TMPDIR/xchg/exit-status")"
        ''}
      '';
    };
}
