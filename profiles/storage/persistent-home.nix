{ config, lib, ... }:

let
  cfg = config.qubix.homeDisk;
in {
  # /home lives on its own VHDX so that the system disk can be thrown away and
  # rebuilt from Nix at any time without logging the user out of anything.
  #
  # The disk is not formatted by the guest.  Qubix ships a pre-formatted,
  # labelled ext4 seed image (see `spotibox-home-vhdx` in flake.nix) and the
  # Windows controller copies it next to the VM on first `up`.  No device-order
  # guessing, no autoFormat surprises: the label either exists or boot stops.
  #
  # neededForBoot makes stage 1 mount it before user activation runs, so home
  # directories are created on the persistent disk, not on the throwaway root.
  # A missing home disk therefore fails loudly instead of silently giving you
  # a fresh, empty home on every rebuild.
  config = lib.mkIf cfg.enable {
    fileSystems."/home" = {
      device = "/dev/disk/by-label/${cfg.label}";
      fsType = "ext4";
      neededForBoot = true;
      options = [ "noatime" "nodev" "nosuid" ];
    };
  };
}
