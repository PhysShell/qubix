{ config, lib, ... }:

let
  net = config.qubix.network;
  hasStatic = net.staticIp != null;
in {
  # Disable predictable interface names so the first NIC is always eth0.
  # Hyper-V guests expose one synthetic NIC; a fixed name avoids interface
  # rename surprises across kernel or driver updates.  Safe here because
  # the image is built from scratch on every recreate.
  networking.usePredictableInterfaceNames = false;

  networking.useDHCP = !hasStatic;

  networking.interfaces = lib.optionalAttrs hasStatic {
    eth0.ipv4.addresses = [{
      address = net.staticIp;
      prefixLength = net.prefixLength;
    }];
  };

  # defaultGateway accepts a plain string; NixOS coerces it internally.
  networking.defaultGateway = lib.mkIf hasStatic net.gateway;

  # NixOS writes these to /etc/resolv.conf.
  networking.nameservers = lib.mkIf hasStatic net.nameservers;
}
