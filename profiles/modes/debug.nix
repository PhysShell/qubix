{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.mode == "debug") {
  environment.systemPackages = with pkgs; [
    curl
    wget
    vim
    htop
    strace
    lsof
    pciutils
    usbutils
    iproute2
    dnsutils
    procps
  ];

  services.openssh.enable = lib.mkForce true;
}
