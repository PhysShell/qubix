{ lib, ... }:

{
  imports = [
    ./spotibox.nix
  ];

  networking.hostName = lib.mkForce "spotibox-debug";
  qubix.mode = lib.mkForce "debug";

  # The debug image keeps nixpkgs' distribution kernel.  It is the thing a
  # minimal kernel gets compared against, and an image whose whole job is to
  # explain a hardware problem should not be missing the driver that explains
  # it.
  qubix.kernel = lib.mkForce "default";
}
