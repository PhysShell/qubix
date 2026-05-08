{ lib, ... }:

{
  imports = [
    ../modules/qubix-options.nix
    ./network/default.nix
  ];

  system.stateVersion = "25.11";

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  networking.hostName = lib.mkDefault "qubix";
  # networking.useDHCP is managed by profiles/network/default.nix based on
  # qubix.network.staticIp.  Default is DHCP (staticIp = null).
  time.timeZone = lib.mkDefault "Asia/Almaty";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Keep the VM friendly to Hyper-V without making Hyper-V the source of truth.
  # Qubix still treats the guest OS image as declarative Nix output.
  virtualisation.hypervGuest.enable = lib.mkDefault true;

  documentation.nixos.enable = lib.mkDefault false;
}
