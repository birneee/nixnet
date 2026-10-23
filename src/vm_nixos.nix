# The NixOS configuration of a node's VM: the node's name and networking, a NIC per interface,
# and the power-off after its awaited services.
{
  lib,
  name,
  node,
  # see vm.nix
  nics,
}:
{
  config,
  modulesPath,
  pkgs,
  ...
}:
{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    node.vm
  ];
  networking =
    let
      # networkd needs a gateway's interface; without one, vm.nix asserts a single NIC
      withInterface =
        gateway:
        if gateway != null && gateway.interface == null then
          gateway // { interface = (lib.head nics).iface; }
        else
          gateway;
    in
    {
      hostName = name;
      useNetworkd = true;
      useDHCP = false;
      firewall.enable = lib.mkDefault false;
      interfaces = lib.mapAttrs (_: iface: { inherit (iface) ipv4 ipv6; }) node.networking.interfaces;
      defaultGateway = withInterface node.networking.defaultGateway;
      defaultGateway6 = withInterface node.networking.defaultGateway6;
    };
  systemd = {
    # a link file per NIC, named like the interface; udev applies only the first match in file
    # name order, so systemd's catch-all, sorting first, is masked
    network.links = lib.listToAttrs (
      map (
        nic:
        lib.nameValuePair nic.iface {
          matchConfig.Path = "pci-0000:00:${nic.slot}.0";
          linkConfig = {
            Name = nic.iface;
          }
          // lib.optionalAttrs (nic.mtu != null) { MTUBytes = toString nic.mtu; };
        }
      ) nics
    );
    # once all awaited services (vmService) finished: their exit status for vm.nix's script, via
    # run-nixos-vm's xchg, the first failed one's if any, then power off
    services.nixnet-poweroff =
      let
        awaitedUnits = map (name: "${name}.service") (
          lib.attrNames (
            # not itself, its own unitConfig follows from this
            lib.filterAttrs (
              name: service: name != "nixnet-poweroff" && service.unitConfig ? X-NixnetAwait
            ) config.systemd.services
          )
        );
      in
      {
        enable = awaitedUnits != [ ];
        wantedBy = [ "multi-user.target" ];
        wants = awaitedUnits;
        after = awaitedUnits;
        serviceConfig.Type = "oneshot";
        script = ''
          status=0
          for unit in ${toString awaitedUnits}; do
            if [ "$status" = 0 ] && [ "$(systemctl show --property Result --value "$unit")" != success ]; then
              status=$(systemctl show --property ExecMainStatus --value "$unit")
              [ "$status" != 0 ] || status=1
            fi
          done
          echo "$status" > /tmp/xchg/exit-status
          systemctl poweroff --no-block
        '';
      };
  };
  environment.etc."systemd/network/99-default.link".source = "/dev/null";
  boot = {
    initrd.systemd.contents."/etc/systemd/network/99-default.link".source = "/dev/null";
    # a failed boot panics and reboots, which ends QEMU (-no-reboot), as in NixOS tests
    kernelParams = [
      "panic=1"
      "boot.panic_on_fail"
    ];
  };
  virtualisation = {
    # root on tmpfs, nothing left behind
    diskImage = null;
    graphics = false;
    qemu = {
      # without GUIs and foreign targets, as in NixOS tests
      package = lib.mkDefault pkgs.qemu_test;
      # kvm, never the much slower emulation (TCG)
      forceAccel = true;
      options = [ "-no-reboot" ];
      # expanded by run-nixos-vm, from vm.nix's script; no default NIC, also without interfaces
      networkingOptions = lib.mkForce [
        "-nic none"
        "$NIXNET_NIC_ARGS"
      ];
    };
    sharedDirectories.pwd = {
      source = ''"$NIXNET_PWD"'';
      target = "/pwd";
      securityModel = "none";
    };
  };
  # a smaller closure, as in NixOS tests (nixos/lib/testing)
  documentation.enable = lib.mkDefault false;
  system = {
    switch.enable = lib.mkDefault false;
    stateVersion = lib.mkDefault lib.trivial.release;
  };
}
